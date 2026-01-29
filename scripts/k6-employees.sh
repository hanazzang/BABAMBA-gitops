#!/usr/bin/env bash
set -euo pipefail

# /employees 부하테스트(토큰 포함) - 복붙용 "한 방" 스크립트
#
# - auth에서 JWT 발급(파드 로그에서 JWT만 추출 → attach/wait 흔들림 제거)
# - gateway 내부 DNS로 /employee/employees 호출 (HTTPRoute hostnames 매칭 위해 Host 헤더 포함)
#
# 사용:
#   RATE=800 DURATION=2m ./scripts/k6-employees.sh
#
# 환경변수:
# - AUTH_BASE (default: http://auth-server-stable.auth.svc:5001)
# - AUTH_USER (default: kosa_demo)
# - AUTH_PASS (default: kosa1004)
# - EMP_URL   (default: http://service-gateway.gateway.svc.cluster.local/employee/employees)
# - HOST_HEADER (default: api.yongun.shop)
# - RATE (default: 800), DURATION (default: 2m), PREALLOCATED_VUS (default: RATE), MAX_VUS (default: 2000)
# - TIMEOUT (default: 10s)

AUTH_BASE="${AUTH_BASE:-http://auth-server-stable.auth.svc:5001}"
AUTH_USER="${AUTH_USER:-kosa_demo}"
AUTH_PASS="${AUTH_PASS:-kosa1004}"

EMP_URL="${EMP_URL:-http://service-gateway.gateway.svc.cluster.local/employee/employees}"
HOST_HEADER="${HOST_HEADER:-api.yongun.shop}"

RATE="${RATE:-800}"
DURATION="${DURATION:-2m}"
PREALLOCATED_VUS="${PREALLOCATED_VUS:-$RATE}"
MAX_VUS="${MAX_VUS:-2000}"
TIMEOUT="${TIMEOUT:-10s}"

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
  '${EMP_URL}'
" || true
set -e

echo "[INFO] start k6: RATE=${RATE} DURATION=${DURATION}"
kubectl -n "${NS_K6}" delete pod k6-employees --ignore-not-found >/dev/null 2>&1 || true

echo "[INFO] starting k8s watcher (every 5s)..."
watch_k8s &
WATCH_PID=$!
trap 'kill "${WATCH_PID}" >/dev/null 2>&1 || true' EXIT

kubectl -n "${NS_K6}" run k6-employees --rm -i --restart=Never --image="${K6_IMAGE}" \
  --env="EMP_URL=${EMP_URL}" \
  --env="HOST_HEADER=${HOST_HEADER}" \
  --env="TOKEN=${TOKEN}" \
  --env="RATE=${RATE}" \
  --env="DURATION=${DURATION}" \
  --env="PREALLOCATED_VUS=${PREALLOCATED_VUS}" \
  --env="MAX_VUS=${MAX_VUS}" \
  --env="TIMEOUT=${TIMEOUT}" \
  --command -- sh -lc '
set -euo pipefail

cat > /tmp/test.js <<'"'"'EOF'"'"'
import http from "k6/http";
import { check, sleep } from "k6";

export const options = {
  scenarios: {
    steady: {
      executor: "constant-arrival-rate",
      rate: Number(__ENV.RATE || 800),
      timeUnit: "1s",
      duration: __ENV.DURATION || "2m",
      preAllocatedVUs: Number(__ENV.PREALLOCATED_VUS || 800),
      maxVUs: Number(__ENV.MAX_VUS || 2000),
    },
  },
};

const url = __ENV.EMP_URL;
const host = __ENV.HOST_HEADER || "";
const token = __ENV.TOKEN;
const timeout = __ENV.TIMEOUT || "10s";

export default function () {
  const headers = { Authorization: `Bearer ${token}` };
  if (host) headers["Host"] = host;
  const res = http.get(url, { timeout, headers });
  check(res, { "status is 200": (r) => r.status === 200 });
  sleep(0.01);
}
EOF

k6 run /tmp/test.js
'

kill "${WATCH_PID}" >/dev/null 2>&1 || true
trap - EXIT

snapshot_k8s

