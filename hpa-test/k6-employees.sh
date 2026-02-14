#!/usr/bin/env bash
set -euo pipefail  # 중간실패시 즉시종료

# /employees 부하테스트(토큰 포함) - 복붙용 "한 방" 스크립트
#
# - auth에서 JWT 발급(파드 로그에서 JWT만 추출 → attach/wait 흔들림 제거)
# - gateway 내부 DNS로 GET/WRITE 호출 (HTTPRoute hostnames 매칭 위해 Host 헤더 포함)
#
# 사용:
#   # GET만(기존과 동일)
#   RATE=200 DURATION=2m ./hpa-test/k6-employees.sh
#
#   # WRITE만(직원 등록/수정. 사진 포함 시 employee_server에서 PIL 리사이즈 CPU 부하)
#   WRITE_RATE=50 GET_RATE=0 DURATION=2m ./hpa-test/k6-employees.sh
#
#   # GET + WRITE 혼합
#   GET_RATE=50 WRITE_RATE=50 DURATION=2m ./hpa-test/k6-employees.sh
#
# 환경변수:
# - AUTH_BASE (default: http://auth-server-stable.auth.svc:5001)
# - AUTH_USER (default: kosa_demo)
# - AUTH_PASS (default: kosa1004)
# - EMP_URL   (default: http://service-gateway.gateway.svc.cluster.local/employee/employees)
# - EMP_GET_URL / EMP_WRITE_URL (미지정 시 EMP_URL로부터 자동 파생)
# - HOST_HEADER (default: api.yongun.shop)
# - RATE (default: 200)
# - GET_RATE (default: RATE), WRITE_RATE (default: 0)
# - DURATION (default: 2m), PREALLOCATED_VUS (default: RATE), MAX_VUS (default: 2000)
# - PHOTO_PCT (default: 70)        # WRITE 중 사진(리사이즈) 포함 비율(%)
# - POST_THEN_GET_PCT (default: 30) # WRITE 성공 후 목록 확인 GET 비율(%)
# - TIMEOUT (default: 10s)

AUTH_BASE="${AUTH_BASE:-http://auth-server-stable.auth.svc:5001}"  # auth 서비스 주소
AUTH_USER="${AUTH_USER:-kosa_demo}"  # auth 서비스 사용자 이름
AUTH_PASS="${AUTH_PASS:-kosa1004}"  # auth 서비스 사용자 비밀번호

EMP_URL="${EMP_URL:-http://service-gateway.gateway.svc.cluster.local/employee/employees}" #  gateway 내부 DNS로 employee 엔드포인트 호출
EMP_GET_URL="${EMP_GET_URL:-$EMP_URL}"
# HTTPRoute는 /employee prefix를 /로 rewrite 합니다.
# 내부가 POST /employee 라면, 외부는 /employee/employee 로 호출해야 함.
EMP_WRITE_URL="${EMP_WRITE_URL:-${EMP_GET_URL%/employees}/employee}"
HOST_HEADER="${HOST_HEADER:-api.yongun.shop}"

RATE="${RATE:-200}"
GET_RATE="${GET_RATE:-$RATE}"
WRITE_RATE="${WRITE_RATE:-0}"
DURATION="${DURATION:-2m}"
PREALLOCATED_VUS="${PREALLOCATED_VUS:-$RATE}"
MAX_VUS="${MAX_VUS:-2000}"
TIMEOUT="${TIMEOUT:-10s}"
PHOTO_PCT="${PHOTO_PCT:-70}"
POST_THEN_GET_PCT="${POST_THEN_GET_PCT:-30}"

K6_IMAGE="${K6_IMAGE:-grafana/k6:0.49.0}"
NS_AUTH="${NS_AUTH:-auth}"
NS_K6="${NS_K6:-k6}"
NS_EMPLOYEE="${NS_EMPLOYEE:-employee}"

# 사전 체크(단건 curl) 타임아웃. 부하가 큰 상태에서도 스크립트가 끊기지 않게 넉넉히.
CHECK_TIMEOUT="${CHECK_TIMEOUT:-30s}"

EMP_POD_LABEL_SELECTOR="${EMP_POD_LABEL_SELECTOR:-app.kubernetes.io/name=employee-server}"

jwt_re='[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'

snapshot_k8s() {
  echo
  echo "[K8S] $(date -u +'%Y-%m-%dT%H:%M:%SZ')"
  echo "[K8S] employee scalers:"
  kubectl -n "${NS_EMPLOYEE}" get hpa,scaledobject 2>/dev/null || true
  echo "[K8S] employee pods:"
  kubectl -n "${NS_EMPLOYEE}" get pods -l "${EMP_POD_LABEL_SELECTOR}" -o wide 2>/dev/null || true
  echo
}

watch_k8s() {
  # 5초마다 파드수만 요약 출력 (터미널 스팸 최소화)
  while true; do
    local total ready
    total="$(kubectl -n "${NS_EMPLOYEE}" get pods -l "${EMP_POD_LABEL_SELECTOR}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$(kubectl -n "${NS_EMPLOYEE}" get pods -l "${EMP_POD_LABEL_SELECTOR}" --no-headers 2>/dev/null | awk '{print $2}' | awk -F/ '$1==$2{c++} END{print c+0}')"
    echo "[K8S] pods_ready=${ready}/${total}"
    sleep 5
  done
}

echo "[INFO] issuing token from auth..."
kubectl -n "${NS_AUTH}" delete pod get-token --ignore-not-found >/dev/null 2>&1 || true

kubectl -n "${NS_AUTH}" run get-token --restart=Never --image=curlimages/curl --command -- sh -lc "
set -e
AUTH_BASE='${AUTH_BASE}'
payload='{\"username\":\"${AUTH_USER}\",\"password\":\"${AUTH_PASS}\"}'
curl -sS --max-time 8 -X POST \"\${AUTH_BASE}/auth/login\" \
  -H 'Content-Type: application/json' \
  -d \"\$payload\"
"

# 최대 30초 동안 로그에서 JWT 추출
TOKEN=""
for _ in $(seq 1 30); do
  TOKEN="$(kubectl -n "${NS_AUTH}" logs get-token 2>/dev/null | grep -Eo "${jwt_re}" | tail -n 1 | tr -d '\r\n' || true)"
  if [[ -n "${TOKEN}" ]]; then break; fi
  sleep 1
done

kubectl -n "${NS_AUTH}" delete pod get-token --ignore-not-found >/dev/null 2>&1 || true

echo "TOKEN_LEN=${#TOKEN}"
echo "${TOKEN}" | awk -F. '{print "JWT_PARTS="NF}'

if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] TOKEN 추출 실패. auth 응답/로그를 확인하세요."
  exit 1
fi

snapshot_k8s

echo "[INFO] quick check /employees (non-fatal)..."
set +e
kubectl -n "${NS_K6}" run emp-check --rm -i --restart=Never --image=curlimages/curl \
  --env="TOKEN=${TOKEN}" --command -- sh -lc "
curl -sS --max-time ${CHECK_TIMEOUT} -o /dev/null -w 'HTTP=%{http_code}\n' \
  -H 'Host: ${HOST_HEADER}' \
  -H 'Authorization: Bearer ${TOKEN}' \
  '${EMP_GET_URL}'
" || true
set -e

echo "[INFO] start k6: GET_RATE=${GET_RATE} WRITE_RATE=${WRITE_RATE} DURATION=${DURATION}"
kubectl -n "${NS_K6}" delete pod k6-employees --ignore-not-found >/dev/null 2>&1 || true

echo "[INFO] starting k8s watcher (every 5s)..."
watch_k8s &
WATCH_PID=$!
trap 'kill "${WATCH_PID}" >/dev/null 2>&1 || true' EXIT

kubectl -n "${NS_K6}" run k6-employees --rm -i --restart=Never --image="${K6_IMAGE}" \
  --env="EMP_GET_URL=${EMP_GET_URL}" \
  --env="EMP_WRITE_URL=${EMP_WRITE_URL}" \
  --env="HOST_HEADER=${HOST_HEADER}" \
  --env="TOKEN=${TOKEN}" \
  --env="GET_RATE=${GET_RATE}" \
  --env="WRITE_RATE=${WRITE_RATE}" \
  --env="DURATION=${DURATION}" \
  --env="PREALLOCATED_VUS=${PREALLOCATED_VUS}" \
  --env="MAX_VUS=${MAX_VUS}" \
  --env="TIMEOUT=${TIMEOUT}" \
  --env="PHOTO_PCT=${PHOTO_PCT}" \
  --env="POST_THEN_GET_PCT=${POST_THEN_GET_PCT}" \
  --command -- sh -lc '
set -euo pipefail

cat > /tmp/test.js <<'"'"'EOF'"'"'
import http from "k6/http";
import { check, sleep } from "k6";
import encoding from "k6/encoding";

export const options = {
  scenarios: {},
};

const getUrl = __ENV.EMP_GET_URL;
const writeUrl = __ENV.EMP_WRITE_URL;
const host = __ENV.HOST_HEADER || "";
const token = __ENV.TOKEN;
const timeout = __ENV.TIMEOUT || "10s";
const duration = __ENV.DURATION || "2m";
const getRate = Number(__ENV.GET_RATE || 0);
const writeRate = Number(__ENV.WRITE_RATE || 0);
const photoPct = Number(__ENV.PHOTO_PCT || 70); // %
const postThenGetPct = Number(__ENV.POST_THEN_GET_PCT || 30); // %

// 1x1 PNG (valid image) to trigger PIL resize path
const tinyPngB64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6Xn2gAAAABJRU5ErkJggg==";
const tinyPngBytes = encoding.b64decode(tinyPngB64, "std");

if (getRate > 0) {
  options.scenarios.get = {
    executor: "constant-arrival-rate",
    rate: getRate,
    timeUnit: "1s",
    duration,
    preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || getRate),
    maxVUs: Number(__ENV.MAX_VUS || 2000),
    exec: "getEmployees",
  };
}

if (writeRate > 0) {
  options.scenarios.write = {
    executor: "constant-arrival-rate",
    rate: writeRate,
    timeUnit: "1s",
    duration,
    preAllocatedVUs: Math.max(1, writeRate),
    maxVUs: Number(__ENV.MAX_VUS || 2000),
    exec: "writeEmployee",
  };
}

const baseHeaders = { Authorization: `Bearer ${token}` };
if (host) baseHeaders["Host"] = host;

let lastEmployeeId = null;

export function getEmployees() {
  const res = http.get(getUrl, { timeout, headers: baseHeaders });
  check(res, { "GET /employees status is 200": (r) => r.status === 200 });
  sleep(0.01);
}

export function writeEmployee() {
  // 일부는 update로 전환(같은 사용자가 여러 번 수정하는 UX를 흉내)
  const doUpdate = lastEmployeeId !== null && Math.random() < 0.2;

  const payload = {
    full_name: `k6-user-${__VU}-${__ITER}`,
    location: "seoul",
    job_title: "engineer",
    badges: "k6",
  };

  if (doUpdate) payload["employee_id"] = String(lastEmployeeId);

  // 사진을 일정 비율로 포함 → employee_server에서 PIL resize CPU 부하 발생
  if (Math.random() * 100 < photoPct) {
    payload["photo"] = http.file(tinyPngBytes, "photo.png", "image/png");
  }

  const res = http.post(writeUrl, payload, { timeout, headers: baseHeaders });
  check(res, { "POST /employee status is 200": (r) => r.status === 200 });

  // 응답에서 id를 잡아 다음 update에 사용
  if (res.status === 200) {
    try {
      const body = res.json();
      if (body && body.id) lastEmployeeId = body.id;
    } catch (e) {
      // ignore
    }
  }

  // 등록 후 “잘 들어갔나?” 목록 확인 GET (일부 비율)
  if (postThenGetPct > 0 && Math.random() * 100 < postThenGetPct) {
    const r2 = http.get(getUrl, { timeout, headers: baseHeaders });
    check(r2, { "POST->GET /employees status is 200": (r) => r.status === 200 });
  }

  sleep(0.01);
}

export default function () {
  // scenarios 모드: 여기서는 사용하지 않음(필수 export만 유지)
  sleep(1);
}
EOF

k6 run /tmp/test.js
'

kill "${WATCH_PID}" >/dev/null 2>&1 || true
trap - EXIT

snapshot_k8s

