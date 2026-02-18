#!/usr/bin/env bash
set -euo pipefail  # bash 엄격모드: 에러/미정의변수/파이프 실패를 즉시 실패로 처리

# /employees 부하테스트(토큰 포함) - 복붙용 "한 방" 스크립트
#
# - auth에서 JWT 발급(파드 로그에서 JWT만 추출 → attach/wait 흔들림 제거)
# - gateway 내부 DNS로 GET/WRITE 호출 (HTTPRoute hostnames 매칭 위해 Host 헤더 포함)
#
# 이 스크립트가 하는 일(큰 흐름)
# 1) (auth ns) 임시 curl 파드로 /auth/login 호출 → JWT 토큰 획득
# 2) (employee ns) 부하 전 스케일러/파드 상태 snapshot 출력
# 3) (k6 ns) 단건 curl로 /employees 빠른 체크(실패해도 진행)
# 4) (employee ns) 5초마다 pods ready/total 출력(관찰용 watcher)
# 5) (k6 ns) k6 파드를 실행해서, 컨테이너 안에서 JS 테스트 생성 → k6 run 수행
# 6) watcher 종료 후 부하 후 snapshot 출력
#
# 사용:
#   # (사전) 결정론적 계정(k6_user_000001 등)을 쓰는 구조라면, 아래로 1번 계정을 미리 생성해둘 수 있습니다.
#   # USERS=1 ./hpa-test/seed-auth-users.sh
#
#   # GET만
#   RATE=200 DURATION=2m ./hpa-test/k6-employees-1id.sh
#
#   # WRITE만(직원 등록/수정. 사진 포함 시 employee_server에서 PIL 리사이즈 CPU 부하)
#   WRITE_RATE=50 GET_RATE=0 DURATION=2m ./hpa-test/k6-employees-1id.sh
#
#   # GET + WRITE 혼합
#   GET_RATE=50 WRITE_RATE=50 DURATION=2m ./hpa-test/k6-employees-1id.sh
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

# =========================
# 0) 환경변수 기본값 설정
# =========================
# - AUTH_*: auth-server 로그인에 사용될 "단일 계정" (즉, 토큰 1개를 공유하는 부하)
# - EMP_*: gateway 내부 DNS로 employee 엔드포인트 호출
# - *_RATE/DURATION 등: k6 시나리오 파라미터
AUTH_BASE="${AUTH_BASE:-http://auth-server-stable.auth.svc:5001}"  # auth 서비스 주소
# 기본값은 "결정론적 테스트 계정" (seed-auth-users.sh가 생성하는 규칙 계정)
# - 필요하면 AUTH_USER/AUTH_PASS를 환경변수로 바꿔서 실행하세요.
AUTH_USER="${AUTH_USER:-k6_user_000001}"  # auth 서비스 사용자 이름
AUTH_PASS="${AUTH_PASS:-k6_pass_000001}"  # auth 서비스 사용자 비밀번호

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

# JWT는 보통 "header.payload.signature" 3파트(dot 2개)로 보이며,
# 아래 정규식으로 파드 로그에서 JWT 형태만 뽑아냅니다.
jwt_re='[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'

# =========================
# 1) 관찰용 유틸 함수
# =========================
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
  # - total: 현재 employee-server 파드 수
  # - ready: READY 컬럼에서 1/1 처럼 준비완료인 파드 수
  while true; do
    local total ready
    total="$(kubectl -n "${NS_EMPLOYEE}" get pods -l "${EMP_POD_LABEL_SELECTOR}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$(kubectl -n "${NS_EMPLOYEE}" get pods -l "${EMP_POD_LABEL_SELECTOR}" --no-headers 2>/dev/null | awk '{print $2}' | awk -F/ '$1==$2{c++} END{print c+0}')"
    echo "[K8S] pods_ready=${ready}/${total}"
    sleep 5
  done
}

# =========================
# 2) auth에서 JWT 토큰 발급
# =========================
# 중요한 포인트:
# - "로컬 curl"이 아니라 "클러스터 내부에서 curl"을 수행해야
#   서비스 DNS(auth-server-stable.auth.svc 등)로 안정적으로 붙습니다.
# - attach/wait 없이, 임시 파드(get-token)를 띄운 뒤 "로그에서 JWT만 추출"합니다.
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
# - 파드 스케줄/실행/로그 출력이 약간 늦을 수 있어 재시도합니다.
# - token을 얻으면 즉시 다음 단계로 진행합니다.
TOKEN=""
for _ in $(seq 1 30); do
  TOKEN="$(kubectl -n "${NS_AUTH}" logs get-token 2>/dev/null | grep -Eo "${jwt_re}" | tail -n 1 | tr -d '\r\n' || true)"
  if [[ -n "${TOKEN}" ]]; then break; fi
  sleep 1
done

# 임시 파드 정리(성공/실패 무관)
kubectl -n "${NS_AUTH}" delete pod get-token --ignore-not-found >/dev/null 2>&1 || true

# 디버깅 힌트(토큰이 맞게 뽑혔는지 최소 정보만 출력)
echo "TOKEN_LEN=${#TOKEN}"
echo "${TOKEN}" | awk -F. '{print "JWT_PARTS="NF}'

if [[ -z "${TOKEN}" ]]; then
  echo "[ERROR] TOKEN 추출 실패. auth 응답/로그를 확인하세요."
  exit 1
fi

# =========================
# 3) 부하 전 상태 스냅샷 + 단건 체크
# =========================
snapshot_k8s

echo "[INFO] quick check /employees (non-fatal)..."
# 여기 체크는 "실패해도 전체 테스트는 진행"하도록 구성합니다.
# - 예: 배포 직후 잠깐 503이거나, 순간적으로 응답이 느린 경우에도 부하 자체는 걸어보고 싶을 때
set +e
kubectl -n "${NS_K6}" run emp-check --rm -i --restart=Never --image=curlimages/curl \
  --env="TOKEN=${TOKEN}" --command -- sh -lc "
curl -sS --max-time ${CHECK_TIMEOUT} -o /dev/null -w 'HTTP=%{http_code}\n' \
  -H 'Host: ${HOST_HEADER}' \
  -H 'Authorization: Bearer ${TOKEN}' \
  '${EMP_GET_URL}'
" || true
set -e

# =========================
# 4) k6 실행(쿠버네티스에서)
# =========================
# - k6는 JS 테스트를 실행합니다.
# - 이 스크립트는 k6 파드를 띄우고(이미지: grafana/k6), 컨테이너 안에서 /tmp/test.js 생성 후 k6 run 수행합니다.
echo "[INFO] start k6: GET_RATE=${GET_RATE} WRITE_RATE=${WRITE_RATE} DURATION=${DURATION}"
kubectl -n "${NS_K6}" delete pod k6-employees --ignore-not-found >/dev/null 2>&1 || true

echo "[INFO] starting k8s watcher (every 5s)..."
watch_k8s &
WATCH_PID=$!
# 스크립트가 중간에 끝나도(에러/CTRL+C) watcher 백그라운드 프로세스는 정리되도록 trap을 겁니다.
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

# ---- k6 테스트 스크립트 생성(JS) ----
# JS 안에서 사용하는 환경변수:
# - __ENV.TOKEN: 위에서 발급한 JWT(모든 VU가 공유 → "1개의 로그인 아이디" 부하)
# - __ENV.EMP_GET_URL / EMP_WRITE_URL: 대상 엔드포인트
# - __ENV.GET_RATE / WRITE_RATE / DURATION: 시나리오 트래픽 파라미터
# - __ENV.PHOTO_PCT: WRITE 요청 중 사진 첨부 비율(사진 첨부 시 서버에서 이미지 리사이즈/처리로 CPU 부하 유발)
# - __ENV.POST_THEN_GET_PCT: WRITE 직후 새로고침(GET) 비율(“등록 후 목록 확인” UX 흉내)
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
    // constant-arrival-rate:
    // - "초당 rate건"으로 요청이 도착하도록(Arrival) 유지하려는 시나리오
    // - 이를 만족하기 위해 k6가 VU를 필요에 따라 사용합니다(preAllocatedVUs/maxVUs 범위)
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

// 모든 요청에 공통으로 들어갈 헤더
// - Authorization: 토큰 기반 인증
// - Host: HTTPRoute hostnames 매칭을 위해 필요할 수 있음(가상호스트)
const baseHeaders = { Authorization: `Bearer ${token}` };
if (host) baseHeaders["Host"] = host;

// 각 VU(가상사용자) 별로 유지되는 상태값
// - 같은 VU가 "등록 후 일부는 수정(update)"까지 하는 흐름을 흉내내기 위해 사용
let lastEmployeeId = null;

export function getEmployees() {
  const res = http.get(getUrl, { timeout, headers: baseHeaders });
  check(res, { "GET /employees status is 200": (r) => r.status === 200 });
  sleep(0.01);
}

export function writeEmployee() {
  // 일부는 update로 전환(같은 사용자가 여러 번 수정하는 UX를 흉내)
  const doUpdate = lastEmployeeId !== null && Math.random() < 0.2;

  // __VU: 가상 사용자 번호(1부터)
  // __ITER: 해당 VU의 반복 횟수(0부터)
  // → full_name을 매번 다르게 만들어 중복을 줄임
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

  // 주의: payload에 http.file이 들어가면 k6가 multipart/form-data로 전송합니다.
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

# ---- k6 실행 ----
k6 run /tmp/test.js
'

# =========================
# 5) watcher 정리 + 부하 후 스냅샷
# =========================
kill "${WATCH_PID}" >/dev/null 2>&1 || true
trap - EXIT

snapshot_k8s

