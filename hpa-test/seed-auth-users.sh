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
#   USERS=100 ./hpa-test/seed-auth-users.sh
#   USERS=5000 AUTH_REGISTER_PATH=/auth/signup ./hpa-test/seed-auth-users.sh
#
# 결과물
# - DB에 사용자 1..USERS가 존재하게 됨(없으면 생성, 있으면 스킵)

USERS="${USERS:-100}"
NS_K6="${NS_K6:-k6}"
NS_AUTH="${NS_AUTH:-auth}"

AUTH_BASE="${AUTH_BASE:-http://auth-server-stable.auth.svc:5001}"
AUTH_REGISTER_PATH="${AUTH_REGISTER_PATH:-/auth/register}"

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
            - name: USER_PREFIX
              value: "${USER_PREFIX}"
            - name: PASS_PREFIX
              value: "${PASS_PREFIX}"
            - name: USER_PAD
              value: "${USER_PAD}"
          command: ["sh", "-lc"]
          args:
            - |
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
                # username/password payload은 login과 동일한 형태를 가정
                payload=$(printf '{"username":"%s","password":"%s"}' "$u" "$p")
                code=$(curl -sS -o /dev/null -w "%{http_code}" \
                  --max-time 10 \
                  -X POST "${AUTH_BASE}${AUTH_REGISTER_PATH}" \
                  -H "Content-Type: application/json" \
                  -d "$payload" || echo "000")
                case "$code" in
                  200|201)
                    ok=$((ok+1))
                    ;;
                  409)
                    # already exists
                    exists=$((exists+1))
                    ;;
                  *)
                    fail=$((fail+1))
                    echo "[WARN] register failed: idx=$i user=$u code=$code"
                    ;;
                esac
              done
              echo "[RESULT] ok=$ok exists=$exists fail=$fail total=$i"
              # 실패가 있으면 일단 실패로 처리(원하면 FAIL_TOLERANCE로 완화 가능)
              if [ "$fail" -gt 0 ]; then
                echo "[ERROR] some registrations failed. check AUTH_REGISTER_PATH or auth behavior."
                exit 1
              fi
EOF

kubectl -n "${NS_K6}" wait --for=condition=complete "job/${JOB_NAME}" --timeout="${WAIT_TIMEOUT}"

echo
echo "[INFO] seed job logs:"
kubectl -n "${NS_K6}" logs "job/${JOB_NAME}" || true

echo "[INFO] cleanup seed job..."
kubectl -n "${NS_K6}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true

echo "[INFO] done. deterministic users 1..${USERS} should exist in DB now."

