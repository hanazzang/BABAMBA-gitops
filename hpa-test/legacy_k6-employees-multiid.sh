###  legacy
#!/usr/bin/env bash
set -euo pipefail

# 시나리오(요구사항 요약)
# - 오전 10시(테스트 시작 시점)에 N명 사용자가 "동시에" 로그인
# - 각 사용자는 자신의 계정으로:
#   - 초당 5회 WRITE(직원 등록/수정)
#   - 초당 30회 GET(/employees) "새로고침"을 수행
# - N은 100/500/1000/5000 등으로 변경 가능
# - 단일 k6 파드가 버거우면, k6 러너 파드를 여러 개로 분산 실행(Execution Segment 사용)
#
# 핵심 포인트
# - k6는 JS만 실행합니다. 이 파일은 "k6 실행을 쿠버네티스에서 오케스트레이션"하는 bash입니다.
# - Deployment/StatefulSet/Rollout이 아니라 "Job"이 적합합니다(테스트는 run-to-completion).
# - 분산 실행은 Indexed Job + k6 execution segment로 "전체 VU(N명)"를 러너 파드에 나눕니다.
#
# 사용 예시
#   # 100명, 러너 1개(단일 파드), 2분
#   USERS=100 RUNNERS=1 DURATION=2m ./hpa-test/k6-employees-multiid.sh
#
#   # 1000명, 러너 4개로 분산(각 러너는 VU의 1/4만 실행)
#   USERS=1000 RUNNERS=4 DURATION=5m ./hpa-test/k6-employees-multiid.sh
#
#   # 5000명, 러너 10개, GET/WRITE 비율 변경
#   USERS=5000 RUNNERS=10 GETS_PER_SEC=10 WRITES_PER_SEC=1 DURATION=5m ./hpa-test/k6-employees-multiid.sh
#
# 주의(중요)
# - 이 스크립트는 "계정 생성 API"는 호출하지 않습니다.
#   USERS_FILE을 제공하거나, 아래 방식으로 생성되는 (username,password) 쌍이
#   실제 auth DB에 미리 만들어져 있어야 로그인 성공합니다.
#
# 필수 도구
# - kubectl (현재 kube context가 대상 클러스터를 가리켜야 함)

# ===== 공통 파라미터(기본값) =====
AUTH_BASE="${AUTH_BASE:-http://auth-server-stable.auth.svc:5001}"
AUTH_LOGIN_PATH="${AUTH_LOGIN_PATH:-/auth/login}"

EMP_URL="${EMP_URL:-http://service-gateway.gateway.svc.cluster.local/employee/employees}"
EMP_GET_URL="${EMP_GET_URL:-$EMP_URL}"
EMP_WRITE_URL="${EMP_WRITE_URL:-${EMP_GET_URL%/employees}/employee}"
HOST_HEADER="${HOST_HEADER:-api.yongun.shop}"

# "동시 사용자 수" (VU 개수와 1:1 매핑)
USERS="${USERS:-100}"

# 분산 러너 파드 수(1이면 단일 k6 파드)
RUNNERS="${RUNNERS:-1}"

# 사용자당 요청량(초당)
GETS_PER_SEC="${GETS_PER_SEC:-30}"
WRITES_PER_SEC="${WRITES_PER_SEC:-5}"

DURATION="${DURATION:-2m}"
TIMEOUT="${TIMEOUT:-10s}"

PHOTO_PCT="${PHOTO_PCT:-70}"
POST_THEN_GET_PCT="${POST_THEN_GET_PCT:-30}"

K6_IMAGE="${K6_IMAGE:-grafana/k6:0.49.0}"
NS_K6="${NS_K6:-k6}"
NS_EMPLOYEE="${NS_EMPLOYEE:-employee}"
EMP_POD_LABEL_SELECTOR="${EMP_POD_LABEL_SELECTOR:-app.kubernetes.io/name=employee-server}"

# (옵션) 기존 계정 CSV를 제공하면 그대로 사용합니다.
# 포맷: username,password (헤더 없음)
USERS_FILE="${USERS_FILE:-}"

# 계정 생성 규칙(USERS_FILE이 없을 때만 사용)
USER_PREFIX="${USER_PREFIX:-k6_user_}"
PASS_PREFIX="${PASS_PREFIX:-k6_pass_}"

# 리소스 이름(충돌 방지 위해 필요하면 바꿔도 됨)
JOB_NAME="${JOB_NAME:-k6-employees-multiid}"
CM_NAME="${CM_NAME:-k6-employees-multiid}"

# Job 완료 대기 시간(대략 DURATION보다 길게)
WAIT_TIMEOUT="${WAIT_TIMEOUT:-30m}"


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
  while true; do
    local total ready
    total="$(kubectl -n "${NS_EMPLOYEE}" get pods -l "${EMP_POD_LABEL_SELECTOR}" --no-headers 2>/dev/null | wc -l | tr -d ' ')"
    ready="$(kubectl -n "${NS_EMPLOYEE}" get pods -l "${EMP_POD_LABEL_SELECTOR}" --no-headers 2>/dev/null | awk '{print $2}' | awk -F/ '$1==$2{c++} END{print c+0}')"
    echo "[K8S] pods_ready=${ready}/${total}"
    sleep 5
  done
}

generate_users_csv() {
  local out="$1"
  local n="$2"
  : > "${out}"
  # username/password를 "랜덤처럼" 보이게 만들 수 있지만,
  # 실제로는 auth DB에 동일한 규칙으로 미리 생성돼 있어야 로그인됩니다.
  # 여기서는 재현 가능한 규칙(prefix + zero-pad index)을 기본으로 둡니다.
  local i
  for i in $(seq 1 "${n}"); do
    printf "%s%06d,%s%06d\n" "${USER_PREFIX}" "${i}" "${PASS_PREFIX}" "${i}" >> "${out}"
  done
}

build_segment_sequence() {
  # RUNNERS=4 -> "0,1/4,2/4,3/4,1"
  local runners="$1"
  local seq="0"
  local i
  for i in $(seq 1 $((runners - 1))); do
    seq+=",${i}/${runners}"
  done
  seq+=",1"
  echo "${seq}"
}


echo "[INFO] scenario: USERS=${USERS} RUNNERS=${RUNNERS} (GET=${GETS_PER_SEC}/s, WRITE=${WRITES_PER_SEC}/s per user) DURATION=${DURATION}"
echo "[INFO] endpoints: AUTH_BASE=${AUTH_BASE} EMP_GET_URL=${EMP_GET_URL} EMP_WRITE_URL=${EMP_WRITE_URL} HOST_HEADER=${HOST_HEADER}"

if [[ "${RUNNERS}" -lt 1 ]]; then
  echo "[ERROR] RUNNERS must be >= 1" >&2
  exit 2
fi

if [[ "${USERS}" -lt 1 ]]; then
  echo "[ERROR] USERS must be >= 1" >&2
  exit 2
fi

snapshot_k8s

echo "[INFO] preparing users.csv..."
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}" >/dev/null 2>&1 || true' EXIT

USERS_CSV="${TMP_DIR}/users.csv"
if [[ -n "${USERS_FILE}" ]]; then
  if [[ ! -f "${USERS_FILE}" ]]; then
    echo "[ERROR] USERS_FILE not found: ${USERS_FILE}" >&2
    exit 2
  fi
  cp "${USERS_FILE}" "${USERS_CSV}"
else
  generate_users_csv "${USERS_CSV}" "${USERS}"
fi

echo "[INFO] (re)creating ConfigMap: ${CM_NAME} in ns/${NS_K6}"
kubectl -n "${NS_K6}" delete configmap "${CM_NAME}" --ignore-not-found >/dev/null 2>&1 || true

# ConfigMap에 JS와 users.csv를 같이 넣어 k6 러너 파드에 마운트합니다.
cat > "${TMP_DIR}/test.js" <<'EOF'
import http from "k6/http";
import { check, sleep } from "k6";
import { SharedArray } from "k6/data";
import encoding from "k6/encoding";
import exec from "k6/execution";

// k6는 "테스트 스크립트(JS)"만 실행합니다.
// 아래 옵션은 "사용자 N명(=VU N개)"을 고정으로 띄워서,
// 각 VU가 초당 GET 10회, WRITE 1회를 직접 수행하도록(Per-user pacing) 구성합니다.

const AUTH_BASE = __ENV.AUTH_BASE;
const AUTH_LOGIN_PATH = __ENV.AUTH_LOGIN_PATH || "/auth/login";

const getUrl = __ENV.EMP_GET_URL;
const writeUrl = __ENV.EMP_WRITE_URL;
const host = __ENV.HOST_HEADER || "";

const duration = __ENV.DURATION || "2m";
const vus = Number(__ENV.USERS || 100);
const timeout = __ENV.TIMEOUT || "10s";

const getsPerSec = Number(__ENV.GETS_PER_SEC || 10);
const writesPerSec = Number(__ENV.WRITES_PER_SEC || 1);

const photoPct = Number(__ENV.PHOTO_PCT || 70); // %
const postThenGetPct = Number(__ENV.POST_THEN_GET_PCT || 30); // % (WRITE 후 추가 GET 확률)

// JWT 형태를 본문에서 추출하기 위한 정규식(응답이 JSON이든 단순 문자열이든 대응)
const jwtRe = /[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/;

// 1x1 PNG (valid image) to trigger PIL resize path
const tinyPngB64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6Xn2gAAAABJRU5ErkJggg==";
const tinyPngBytes = encoding.b64decode(tinyPngB64, "std");

// users.csv는 k8s ConfigMap으로 마운트됨
// 포맷: username,password (헤더 없음)
const users = new SharedArray("users", () => {
  const raw = open("/test/users.csv").trim();
  if (!raw) return [];
  return raw.split("\n").map((line) => {
    const [username, password] = line.trim().split(",", 2);
    return { username, password };
  });
});

export const options = {
  scenarios: {
    per_user_loop: {
      executor: "constant-vus",
      vus,
      duration,
    },
  },
};

function baseHeaders(token) {
  const h = token ? { Authorization: `Bearer ${token}` } : {};
  if (host) h["Host"] = host;
  return h;
}

function login(username, password) {
  const payload = JSON.stringify({ username, password });
  const res = http.post(`${AUTH_BASE}${AUTH_LOGIN_PATH}`, payload, {
    timeout,
    headers: { "Content-Type": "application/json" },
  });

  // "동시 로그인" 시나리오에서 로그인 실패율은 매우 중요한 지표라서 check를 걸어둡니다.
  check(res, { "login status is 200": (r) => r.status === 200 });
  if (res.status !== 200) return null;

  // auth 응답이 JSON이면 token 필드를, 아니면 JWT 패턴을 body에서 추출
  let token = null;
  try {
    const body = res.json();
    token = body?.access_token || body?.token || body?.jwt || null;
  } catch (e) {
    // ignore
  }
  if (!token) {
    const m = String(res.body || "").match(jwtRe);
    if (m) token = m[0];
  }
  return token;
}

function doGet(token) {
  return http.get(getUrl, { timeout, headers: baseHeaders(token) });
}

function doWrite(token, state) {
  // 같은 사용자(VU)가 일부는 update도 하도록 흉내
  const doUpdate = state.lastEmployeeId !== null && Math.random() < 0.2;
  const payload = {
    full_name: `k6-user-${state.userIdx}-${state.iter}`,
    location: "seoul",
    job_title: "engineer",
    badges: "k6",
  };
  if (doUpdate) payload["employee_id"] = String(state.lastEmployeeId);
  if (Math.random() * 100 < photoPct) {
    payload["photo"] = http.file(tinyPngBytes, "photo.png", "image/png");
  }
  const res = http.post(writeUrl, payload, { timeout, headers: baseHeaders(token) });
  check(res, { "write status is 200": (r) => r.status === 200 });
  if (res.status === 200) {
    try {
      const body = res.json();
      if (body && body.id) state.lastEmployeeId = body.id;
    } catch (e) {
      // ignore
    }
  }
  return res;
}

export default function () {
  // 분산 실행 시에도 "VU -> 유저" 매핑이 흔들리지 않게 global VU id를 사용합니다.
  // exec.vu.idInTest: 테스트 전체 기준 VU ID(1부터). k6 execution segment에도 대응.
  const vuId = exec.vu.idInTest;
  const userIdx = (vuId - 1) % users.length;
  const cred = users[userIdx];

  // VU마다 상태를 들고 갑니다.
  const state = {
    userIdx,
    iter: 0,
    token: null,
    lastEmployeeId: null,
  };

  // 10시에 "동시에 로그인"을 재현: 모든 VU가 시작하자마자 한 번 로그인 시도
  // (실제 시스템에서는 이미 로그인된 세션일 수도 있지만, 부하목적상 login spike를 분리해서 측정하기도 좋음)
  state.token = login(cred.username, cred.password);

  // 로그인 실패하면 이후 요청은 의미가 없으므로, 약간 쉬면서 종료(에러율은 check에서 집계됨)
  if (!state.token) {
    sleep(1);
    return;
  }

  // "사용자당 초당 X회"를 최대한 지키기 위해 1초 주기로 루프를 돈다.
  while (true) {
    const start = Date.now();

    // WRITE: 초당 writesPerSec
    for (let i = 0; i < writesPerSec; i++) {
      doWrite(state.token, state);
    }

    // GET: 초당 getsPerSec (배치로 묶어서 네트워크 오버헤드를 줄임)
    if (getsPerSec > 0) {
      const reqs = [];
      for (let i = 0; i < getsPerSec; i++) {
        reqs.push(["GET", getUrl, null, { timeout, headers: baseHeaders(state.token) }]);
      }
      const resps = http.batch(reqs);
      // batch 결과 중 하나라도 200이 아닌 것을 잡기 위해 간단 체크
      check(resps, { "get batch all 200": (arr) => arr.every((r) => r && r.status === 200) });
    }

    // WRITE 후 “새로고침 GET”을 추가로 하는 UX 흉내(옵션)
    if (postThenGetPct > 0 && Math.random() * 100 < postThenGetPct) {
      const r2 = doGet(state.token);
      check(r2, { "post->refresh get 200": (r) => r.status === 200 });
    }

    state.iter++;

    // 1초 pacing: 처리시간이 1초를 넘으면 sleep(0)로 즉시 다음 루프로 넘어감
    const elapsed = (Date.now() - start) / 1000;
    sleep(Math.max(0, 1 - elapsed));
  }
}
EOF

kubectl -n "${NS_K6}" create configmap "${CM_NAME}" \
  --from-file=test.js="${TMP_DIR}/test.js" \
  --from-file=users.csv="${USERS_CSV}" \
  >/dev/null

K6_SEGMENT_SEQUENCE="$(build_segment_sequence "${RUNNERS}")"
echo "[INFO] k6 execution segment sequence: ${K6_SEGMENT_SEQUENCE}"

echo "[INFO] deleting old Job (if exists): ${JOB_NAME}"
kubectl -n "${NS_K6}" delete job "${JOB_NAME}" --ignore-not-found >/dev/null 2>&1 || true

echo "[INFO] starting k8s watcher (every 5s)..."
watch_k8s &
WATCH_PID=$!
trap 'kill "${WATCH_PID}" >/dev/null 2>&1 || true' EXIT

echo "[INFO] creating Indexed Job: ${JOB_NAME} (RUNNERS=${RUNNERS})"
kubectl -n "${NS_K6}" apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
spec:
  completionMode: Indexed
  completions: ${RUNNERS}
  parallelism: ${RUNNERS}
  backoffLimit: 0
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: ${K6_IMAGE}
          env:
            - name: AUTH_BASE
              value: "${AUTH_BASE}"
            - name: AUTH_LOGIN_PATH
              value: "${AUTH_LOGIN_PATH}"
            - name: EMP_GET_URL
              value: "${EMP_GET_URL}"
            - name: EMP_WRITE_URL
              value: "${EMP_WRITE_URL}"
            - name: HOST_HEADER
              value: "${HOST_HEADER}"
            - name: USERS
              value: "${USERS}"
            - name: DURATION
              value: "${DURATION}"
            - name: TIMEOUT
              value: "${TIMEOUT}"
            - name: GETS_PER_SEC
              value: "${GETS_PER_SEC}"
            - name: WRITES_PER_SEC
              value: "${WRITES_PER_SEC}"
            - name: PHOTO_PCT
              value: "${PHOTO_PCT}"
            - name: POST_THEN_GET_PCT
              value: "${POST_THEN_GET_PCT}"
            - name: RUNNERS
              value: "${RUNNERS}"
            - name: K6_SEGMENT_SEQUENCE
              value: "${K6_SEGMENT_SEQUENCE}"
            - name: JOB_COMPLETION_INDEX
              valueFrom:
                fieldRef:
                  fieldPath: metadata.annotations['batch.kubernetes.io/job-completion-index']
          command: ["sh", "-lc"]
          args:
            - |
              set -euo pipefail
              idx="\${JOB_COMPLETION_INDEX:-0}"
              runners="\${RUNNERS}"
              seq="\${K6_SEGMENT_SEQUENCE}"
              # k6 execution segment (예: 0/4:1/4, 1/4:2/4 ...)
              if [ "\${runners}" = "1" ]; then
                seg="0:1"
              else
                next=\$((idx + 1))
                seg="\${idx}/\${runners}:\${next}/\${runners}"
              fi
              echo "[INFO] runner idx=\${idx} segment=\${seg} seq=\${seq}"
              # 분산 실행: 같은 테스트를 여러 파드에서 실행하되, segment로 VU 범위를 분할
              k6 run \
                --execution-segment "\${seg}" \
                --execution-segment-sequence "\${seq}" \
                /test/test.js
          volumeMounts:
            - name: test
              mountPath: /test
              readOnly: true
      volumes:
        - name: test
          configMap:
            name: ${CM_NAME}
EOF

echo "[INFO] waiting job completion: job/${JOB_NAME} (timeout=${WAIT_TIMEOUT})"
kubectl -n "${NS_K6}" wait --for=condition=complete "job/${JOB_NAME}" --timeout="${WAIT_TIMEOUT}"

echo
echo "[INFO] job completed. printing logs (per runner pod):"
kubectl -n "${NS_K6}" get pods -l job-name="${JOB_NAME}" -o name | while read -r p; do
  echo
  echo "===== logs: ${p} ====="
  kubectl -n "${NS_K6}" logs "${p}" || true
done

kill "${WATCH_PID}" >/dev/null 2>&1 || true
trap - EXIT

snapshot_k8s

echo "[INFO] done."

