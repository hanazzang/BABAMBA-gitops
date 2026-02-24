#!/usr/bin/env bash
set -euo pipefail

# 목적
# - 결정론적 규칙(예: k6_user_000001 / k6_pass_000001)으로 계정을 계산
# - auth 서비스의 "회원가입/유저생성" API를 호출하여 DB에 계정들을 미리 넣어둠
#
# 전제(중요)
# - auth 서버에 "계정 생성" 엔드포인트가 있어야 합니다.
#   기본값: POST /auth/register (없으면 AUTH_REGISTER_PATH로 변경)
# - 이미 만들어진 계정이 있으면(409 등) 그대로 넘어가도록 구성합니다.
#
# 사용 예시
#   USERS=1000 ./hpa-test/seed-auth-users.sh
#   USERS=5000 AUTH_REGISTER_PATH=/auth/signup ./hpa-test/seed-auth-users.sh
#
# 결과물
# - DB에 사용자 1..USERS가 존재하게 됨(없으면 생성, 있으면 스킵)

USERS="${USERS:-1000}"
NS_K6="${NS_K6:-k6}"
NS_AUTH="${NS_AUTH:-auth}"

AUTH_BASE="${AUTH_BASE:-http://auth-server-stable.auth.svc:5001}"
AUTH_REGISTER_PATH="${AUTH_REGISTER_PATH:-/auth/register}"

# seeding 안정화 옵션(일시적 5xx/네트워크 튐 대응)
RETRIES="${RETRIES:-2}"                 # 실패 시 추가 재시도 횟수(총 시도 = 1 + RETRIES)
RETRY_SLEEP_MS="${RETRY_SLEEP_MS:-50}"  # 재시도 간 sleep (ms)
FAIL_TOLERANCE="${FAIL_TOLERANCE:-0}"   # 허용 실패 건수(기본 0 = 1건이라도 실패하면 Job 실패)

# 결정론적 계정 규칙
# 예: USER_PREFIX=k6_user_, PASS_PREFIX=k6_pass_, USER_PAD=6 -> k6_user_000001 / k6_pass_000001
USER_PREFIX="${USER_PREFIX:-k6_user_}"
PASS_PREFIX="${PASS_PREFIX:-k6_pass_}"
USER_PAD="${USER_PAD:-6}"

JOB_NAME="${JOB_NAME:-k6-auth-users-seed}"

WAIT_TIMEOUT="${WAIT_TIMEOUT:-30m}"
MODE="${MODE:-extend}" # extend|replace (결정론적 계정에선 동작 동일: 1..USERS를 생성 시도)

if [[ "${USERS}" -lt 1 ]]; then
  echo "[ERROR] USERS must be >= 1" >&2
  exit 2
fi

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] required command not found: $1" >&2; exit 2; }
}
need_cmd kubectl

echo "[INFO] running seed Job ${JOB_NAME} (MODE=${MODE}, USERS=${USERS}) (calls ${AUTH_BASE}${AUTH_REGISTER_PATH})..."
kubectl -n "${NS_K6}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true

SEED_SCRIPT="$(cat <<'SH'
set -euo pipefail
ok=0
exists=0
fail=0
i=0
while [ "$i" -lt "${USERS}" ]; do
  i=$((i+1))
  suffix=$(printf "%0*d" "${USER_PAD}" "$i")
  u="${USER_PREFIX}${suffix}"
  p="${PASS_PREFIX}${suffix}"
  payload=$(printf '{"username":"%s","password":"%s"}' "$u" "$p")

  attempt=0
  code="000"
  last_body=""
  while :; do
    resp="/tmp/seed_resp_${$}.json"
    code=$(curl -sS -o "${resp}" -w "%{http_code}" \
      --max-time 10 \
      -X POST "${AUTH_BASE}${AUTH_REGISTER_PATH}" \
      -H "Content-Type: application/json" \
      -d "$payload" || echo "000")
    last_body="$(cat "${resp}" 2>/dev/null || true)"
    rm -f "${resp}" || true

    # BABAMBA auth_server는 "중복"을 400으로 반환합니다(409 아님).
    # - {"detail":"이미 존재하는 아이디입니다."}
    if [ "$code" = "400" ]; then
      case "$last_body" in
        *"이미 존재"*) code="409" ;;
      esac
    fi

    case "$code" in
      200|201|409)
        break
        ;;
      5*|000)
        if [ "$attempt" -ge "${RETRIES}" ]; then
          break
        fi
        attempt=$((attempt+1))
        sleep "$(awk "BEGIN { printf \"%.3f\", ${RETRY_SLEEP_MS}/1000 }")"
        ;;
      *)
        break
        ;;
    esac
  done

  case "$code" in
    200|201)
      ok=$((ok+1))
      ;;
    409)
      exists=$((exists+1))
      ;;
    *)
      fail=$((fail+1))
      # 바디가 너무 길면 잡음이 커서 200자만 노출
      short_body="$(printf "%s" "$last_body" | head -c 200)"
      echo "[WARN] register failed: idx=$i user=$u code=$code attempts=$((attempt+1)) body=${short_body}"
      ;;
  esac
done
echo "[RESULT] ok=$ok exists=$exists fail=$fail total=$i"
if [ "$fail" -gt "${FAIL_TOLERANCE}" ]; then
  echo "[ERROR] some registrations failed. check AUTH_REGISTER_PATH or auth behavior."
  exit 1
fi
SH
)"

kubectl -n "${NS_K6}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: seed
          image: curlimages/curl:8.6.0
          env:
            - name: AUTH_BASE
              value: "${AUTH_BASE}"
            - name: AUTH_REGISTER_PATH
              value: "${AUTH_REGISTER_PATH}"
            - name: USERS
              value: "${USERS}"
            - name: RETRIES
              value: "${RETRIES}"
            - name: RETRY_SLEEP_MS
              value: "${RETRY_SLEEP_MS}"
            - name: FAIL_TOLERANCE
              value: "${FAIL_TOLERANCE}"
            - name: USER_PREFIX
              value: "${USER_PREFIX}"
            - name: PASS_PREFIX
              value: "${PASS_PREFIX}"
            - name: USER_PAD
              value: "${USER_PAD}"
          command: ["sh", "-lc"]
          args:
            - |
$(printf '%s\n' "${SEED_SCRIPT}" | sed 's/^/              /')
EOF

kubectl -n "${NS_K6}" wait --for=condition=complete "job/${JOB_NAME}" --timeout="${WAIT_TIMEOUT}"

echo
echo "[INFO] seed job logs:"
kubectl -n "${NS_K6}" logs "job/${JOB_NAME}" || true

echo "[INFO] cleanup seed job..."
kubectl -n "${NS_K6}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true

echo "[INFO] done. deterministic users 1..${USERS} should exist in DB now."

