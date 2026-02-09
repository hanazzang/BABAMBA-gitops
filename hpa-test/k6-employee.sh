#!/usr/bin/env bash
set -euo pipefail

# k6 employee 부하 테스트 (kubectl run 방식)
#
# 기본값:
# - 게이트웨이 "내부 DNS(ClusterIP)"로 호출 (LB 외부IP 헤어핀 타임아웃 방지)
# - HTTPRoute hostnames 매칭을 위한 Host 헤더 포함
# - (중요) 현재 employee의 /employees는 auth 토큰과 호환이 안 되어 401이 날 수 있음
#   그래서 기본은 "인증 없이도 200이 나오는" GET /employee/{id}로 부하를 줍니다.
#   (게이트웨이 경로는 prefix rewrite 때문에 /employee/employee/{id} 로 호출)
#
# 사용 예)
#   # (권장) 토큰 자동 발급 + 800 rps 2분
#   AUTH_USER=kosa_demo AUTH_PASS=kosa1004 ./scripts/k6-employee.sh
#
#   # 토큰 직접 주입
#   TOKEN="eyJ..." ./scripts/k6-employee.sh
#
#   # 부하 강도 변경
#   RATE=200 DURATION=3m ./scripts/k6-employee.sh
#
# 환경변수)
# - EMP_URL: (기본) http://service-gateway.gateway.svc.cluster.local/employee/employee
#            최종 URL은 EMP_URL + "/" + EMP_ID 로 구성됩니다.
# - HOST_HEADER: 기본 api.yongun.shop
# - USE_AUTH=1 인 경우에만 JWT 사용 (/employees 호출용)
# - TOKEN: JWT(있으면 그대로 사용)
# - AUTH_BASE: 기본 http://auth-server-stable.auth.svc:5001
# - AUTH_USER / AUTH_PASS: TOKEN 없을 때 자동 로그인에 사용
# - EMP_ID: 기본 201
# - EMP_ID_MIN / EMP_ID_MAX: 랜덤 ID 범위 (기본 201~400)
# - RATE: 초당 요청수 (default 800)
# - DURATION: 지속시간 (default 2m)
# - PREALLOCATED_VUS: (default RATE와 동일)
# - MAX_VUS: (default 2000)
# - K6_IMAGE: (default grafana/k6:0.49.0)
# - TIMEOUT: (default 10s)

EMP_URL="${EMP_URL:-http://service-gateway.gateway.svc.cluster.local/employee/employee}"
HOST_HEADER="${HOST_HEADER:-api.yongun.shop}"
USE_AUTH="${USE_AUTH:-0}"

AUTH_BASE="${AUTH_BASE:-http://auth-server-stable.auth.svc:5001}"
AUTH_USER="${AUTH_USER:-}"
AUTH_PASS="${AUTH_PASS:-}"

RATE="${RATE:-800}"
DURATION="${DURATION:-2m}"
PREALLOCATED_VUS="${PREALLOCATED_VUS:-$RATE}"
MAX_VUS="${MAX_VUS:-2000}"
K6_IMAGE="${K6_IMAGE:-grafana/k6:0.49.0}"
TIMEOUT="${TIMEOUT:-10s}"

NAMESPACE_K6="${NAMESPACE_K6:-k6}"
NAMESPACE_AUTH="${NAMESPACE_AUTH:-auth}"

get_token_from_auth() {
  local pod="get-token"
  local jwt_re='[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+'

  kubectl -n "${NAMESPACE_AUTH}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true

  kubectl -n "${NAMESPACE_AUTH}" run "${pod}" --restart=Never --image=curlimages/curl --command -- sh -lc "
set -e
AUTH_BASE=\"${AUTH_BASE}\"
payload='{\"username\":\"${AUTH_USER}\",\"password\":\"${AUTH_PASS}\"}'
token=\$(
  curl -sS --max-time 8 -X POST \"\${AUTH_BASE}/auth/login\" \
    -H \"Content-Type: application/json\" \
    -d \"\$payload\" \
  | sed -n 's/.*\"token\":\"\\([^\"]*\\)\".*/\\1/p'
)
[ -n \"\$token\" ] || { echo \"TOKEN_EMPTY\"; exit 1; }
echo \"\$token\"
"

  kubectl -n "${NAMESPACE_AUTH}" wait --for=condition=Succeeded "pod/${pod}" --timeout=60s >/dev/null 2>&1 || true
  local token
  token="$(
    kubectl -n "${NAMESPACE_AUTH}" logs "${pod}" \
      | tr -d '\r' \
      | grep -Eo "${jwt_re}" \
      | tail -n 1
  )"
  kubectl -n "${NAMESPACE_AUTH}" delete pod "${pod}" --ignore-not-found >/dev/null 2>&1 || true

  echo "${token}"
}

TOKEN="${TOKEN:-}"
if [[ "${USE_AUTH}" == "1" && -z "${TOKEN}" ]]; then
  if [[ -z "${AUTH_USER}" || -z "${AUTH_PASS}" ]]; then
    echo "[ERROR] TOKEN이 없고, AUTH_USER/AUTH_PASS도 없습니다."
    echo "        TOKEN을 주거나, AUTH_USER/AUTH_PASS로 자동 로그인 설정을 해주세요."
    exit 1
  fi
  echo "[INFO] TOKEN이 없어서 auth에서 자동 발급합니다."
  TOKEN="$(get_token_from_auth)"
fi

# 헤더에 들어갈 수 있게 토큰 정제(개행/캐리지리턴 제거)
TOKEN="$(printf '%s' "${TOKEN}" | tr -d '\r\n')"

if [[ "${USE_AUTH}" == "1" && -z "${TOKEN}" ]]; then
  echo "[ERROR] TOKEN이 비어있습니다. (로그인 실패 또는 토큰 추출 실패)"
  exit 1
fi

echo "[DEBUG] EMP_URL=${EMP_URL}"
echo "[DEBUG] HOST_HEADER=${HOST_HEADER}"
echo "[DEBUG] USE_AUTH=${USE_AUTH}"
echo "[DEBUG] TOKEN_LEN=${#TOKEN}"
if [[ "${USE_AUTH}" == "1" ]]; then
  echo "${TOKEN}" | awk -F. '{print "[DEBUG] JWT_PARTS="NF}'
fi

EMP_ID="${EMP_ID:-201}"
EMP_ID_MIN="${EMP_ID_MIN:-201}"
EMP_ID_MAX="${EMP_ID_MAX:-400}"

kubectl -n "${NAMESPACE_K6}" delete pod k6-employees --ignore-not-found >/dev/null 2>&1 || true

K6_CMD="$(cat <<'EOS'
set -euo pipefail
echo "[DEBUG] EMP_URL=$EMP_URL"
echo "[DEBUG] HOST_HEADER=$HOST_HEADER"
echo "[DEBUG] USE_AUTH=$USE_AUTH"
echo "[DEBUG] EMP_ID=$EMP_ID (range: $EMP_ID_MIN..$EMP_ID_MAX)"
echo "[DEBUG] RATE=$RATE DURATION=$DURATION PREALLOCATED_VUS=$PREALLOCATED_VUS MAX_VUS=$MAX_VUS TIMEOUT=$TIMEOUT"
echo "[DEBUG] TOKEN_LEN=${#TOKEN}"
if [ "${USE_AUTH}" = "1" ]; then
  [ -n "$TOKEN" ] || { echo "TOKEN is empty. STOP."; exit 1; }
fi

cat > /tmp/test.js <<'EOF'
import http from "k6/http";
import { check, sleep } from "k6";
import { randomIntBetween } from "https://jslib.k6.io/k6-utils/1.4.0/index.js";

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

const base = __ENV.EMP_URL; // e.g. http://.../employee/employee
const token = __ENV.TOKEN || "";
const host = __ENV.HOST_HEADER || "";
const timeout = __ENV.TIMEOUT || "10s";
const useAuth = (__ENV.USE_AUTH || "0") === "1";
const fixedId = Number(__ENV.EMP_ID || 201);
const minId = Number(__ENV.EMP_ID_MIN || 201);
const maxId = Number(__ENV.EMP_ID_MAX || 400);

export default function () {
  const id = (minId <= maxId) ? randomIntBetween(minId, maxId) : fixedId;
  const url = `${base}/${id}`;
  const headers = {};
  if (host) headers["Host"] = host;
  if (useAuth) headers["Authorization"] = `Bearer ${token}`;
  const res = http.get(url, { timeout, headers });
  check(res, { "status is 200": (r) => r.status === 200 });
  sleep(0.01);
}
EOF

k6 run /tmp/test.js
EOS
)"

kubectl -n "${NAMESPACE_K6}" run k6-employees --rm -i --restart=Never --image="${K6_IMAGE}" \
  --env="EMP_URL=${EMP_URL}" \
  --env="HOST_HEADER=${HOST_HEADER}" \
  --env="TOKEN=${TOKEN}" \
  --env="USE_AUTH=${USE_AUTH}" \
  --env="EMP_ID=${EMP_ID}" \
  --env="EMP_ID_MIN=${EMP_ID_MIN}" \
  --env="EMP_ID_MAX=${EMP_ID_MAX}" \
  --env="RATE=${RATE}" \
  --env="DURATION=${DURATION}" \
  --env="PREALLOCATED_VUS=${PREALLOCATED_VUS}" \
  --env="MAX_VUS=${MAX_VUS}" \
  --env="TIMEOUT=${TIMEOUT}" \
  --command -- sh -lc "${K6_CMD}"

