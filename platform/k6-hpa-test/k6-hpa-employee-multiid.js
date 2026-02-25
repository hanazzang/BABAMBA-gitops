import http from "k6/http";
import { check, sleep } from "k6";
import encoding from "k6/encoding";
import exec from "k6/execution";

/**
 * 이 파일이 하는 일(큰 그림)
 * - k6-operator(TestRun)에서 분산 실행되는 k6 runner들이 공통으로 사용할 "부하 시나리오"입니다.
 * - 하나의 파일에서 TEST_MODE를 바꿔가며, 컴포넌트 단독(게이트웨이/로그인/GET-only/WRITE-only)과 E2E를 모두 실행할 수 있게 만들었습니다.
 *
 * 왜 이렇게 만들었나(실무 포인트)
 * - "스케일링 정책 비교"는 단일 E2E로만 하면 원인 분리가 어렵습니다.
 *   → auth 버스트 / employee GET / employee WRITE / gateway-only / (마지막에) E2E 순으로 쪼개서 보는 게 일반적입니다.
 *
 * TEST_MODE (템플릿에서 -e TEST_MODE=... 로 지정)
 * - auth_spike      : 동시 로그인 N명(각 VU 1회 로그인) → auth 버스트 흡수 확인(최악 케이스)
 * - auth_ramp       : duration 동안 로그인 유입을 rate로 분산 → 실무형 로그인 유입(램프) 재현
 * - employee_get    : 로그인 후 GET만 반복 → GET 경로(KEDA/RPS) 반응 확인
 * - employee_write  : 로그인 후 WRITE만 반복 → WRITE 경로(HPA/CPU/MEM) + DB 병목 확인
 * - e2e(기본)       : 로그인 후 GET+WRITE 혼합 → end-to-end 용량/안정성 검증
 * - gateway_only    : 특정 URL만 반복 호출(기본은 로그인 없이) → 게이트웨이 레이어(라우팅/프록시) 한계 확인
 *
 * 분산 실행에서 계정 매핑(중요)
 * - k6-operator parallelism=K 이면 runner 파드가 K개로 쪼개져 실행됩니다.
 * - 이때 "전체 테스트 기준 VU 번호"가 필요해서 exec.vu.idInTest(1..USERS)를 사용합니다.
 *
 * 계정 방식(결정론)
 * - users.csv/Secret 없이, VU 번호로 계정을 계산합니다.
 *   예: k6_user_000001 / k6_pass_000001
 * - 따라서 auth DB에 사용자 1..USERS는 사전에 존재해야 합니다(= seed-auth-users.sh 역할).
 */

const AUTH_BASE = __ENV.AUTH_BASE || "http://auth-server-stable.auth.svc:5001";
const AUTH_LOGIN_PATH = __ENV.AUTH_LOGIN_PATH || "/auth/login";

const mode = (__ENV.TEST_MODE || "e2e").toLowerCase();

const empGetUrl = __ENV.EMP_GET_URL || "";
const empWriteUrl = __ENV.EMP_WRITE_URL || "";
// gateway_only는 "게이트웨이 레이어"가 목적이라, 기본은 템플릿에서 명시적으로 넣는 걸 권장합니다.
// (실수로 EMP_GET_URL 같은 무거운 경로를 gateway-only에 넣으면 백엔드까지 타게 됨)
const gatewayUrl = __ENV.GATEWAY_URL || empGetUrl;
const gatewayNeedsAuth = String(__ENV.GATEWAY_NEEDS_AUTH || "false").toLowerCase() === "true";

const host = __ENV.HOST_HEADER || "";

const duration = __ENV.DURATION || "2m";
// USERS는 "동시 사용자 수"이며 constant-vus에서는 그대로 VU 개수로 사용됩니다.
// (auth_ramp에서는 arrival-rate executor이므로 VU는 풀(preAllocated/maxVUs)로 쓰고, USERS는 "계정 상한"으로 의미가 남습니다.)
const users = Number(__ENV.USERS || 1000);
const timeout = __ENV.TIMEOUT || "10s";

// auth_ramp(로그인 분산) 옵션
// - LOGIN_RATE: 초당 로그인 시도 수(예: 2분에 5000명 로그인 ≒ 42/s)
// - LOGIN_PREALLOCATED_VUS / LOGIN_MAX_VUS: arrival-rate executor용 VU 풀
const loginRate = Number(__ENV.LOGIN_RATE || 42);
const loginPreVUs = Number(__ENV.LOGIN_PREALLOCATED_VUS || 200);
const loginMaxVUs = Number(__ENV.LOGIN_MAX_VUS || users);

// 실무적으로 과격한 값(예: GET 30/s, WRITE 10/s)은 시스템/네트워크를 먼저 쓰러뜨리기 쉬워
// 기본값은 "합리적인 시작점"으로 낮춰두고, 필요하면 ENV로 올리는 방식을 권장합니다.
//
// - GETS_PER_SEC    : 사용자당 초당 GET 기대치 (정수/소수 가능)
// - WRITES_PER_SEC  : 사용자당 초당 WRITE 기대치 (정수/소수 가능)
const getsPerSec = Number(__ENV.GETS_PER_SEC || 2);   // 기본 2/s
const writesPerSec = Number(__ENV.WRITES_PER_SEC || 0.2); // 기본 0.2/s (= 5초에 1회)

const photoPct = Number(__ENV.PHOTO_PCT || 70); // %
const postThenGetPct = Number(__ENV.POST_THEN_GET_PCT || 30); // % (WRITE 후 추가 새로고침 GET)

// 계정 생성 규칙(테스트 시 "id/password가 이미 만들어져 있다"는 전제)
// 예: k6_user_000001 / k6_pass_000001
const userPrefix = __ENV.USER_PREFIX || "k6_user_";
const passPrefix = __ENV.PASS_PREFIX || "k6_pass_";
const userPad = Number(__ENV.USER_PAD || 6);

// auth 응답이 JSON이 아닐 수도 있어 JWT 문자열 패턴도 같이 지원
const jwtRe = /[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+/;

// 1x1 PNG (valid image) to trigger PIL resize path
const tinyPngB64 =
  "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMB/6Xn2gAAAABJRU5ErkJggg==";
const tinyPngBytes = encoding.b64decode(tinyPngB64, "std");

// HTTPS로 Gateway 호출 시 클러스터 내부/자체서명 인증서면 TLS 검증 스킵 (옵션 또는 GATEWAY_URL이 https://일 때)
// 주의: `gatewayUrl && ...`는 gatewayUrl이 ""(빈 문자열)이면 boolean이 아니라 ""를 반환할 수 있어,
// k6 옵션 파싱에서 `json: cannot unmarshal string into ... null.Bool`로 실패합니다.
// 따라서 skipTLS는 항상 boolean이 되도록 강제합니다.
const skipTLS =
  String(__ENV.INSECURE_SKIP_TLS_VERIFY || "").toLowerCase() === "true" ||
  (!!gatewayUrl && gatewayUrl.startsWith("https://"));

export const options = {
  insecureSkipTLSVerify: skipTLS,
  scenarios: {
    ...(mode === "auth_spike"
      ? {
          auth_spike: {
            // 모든 VU가 "딱 1번" 로그인만 수행합니다.
            // - vus=USERS로 두면 users명 로그인 요청이 최대한 동시에 몰립니다(최악 케이스).
            executor: "per-vu-iterations",
            vus: users,
            iterations: 1,
            maxDuration: duration,
            exec: "loginOnce",
          },
        }
      : mode === "auth_ramp"
        ? {
            auth_ramp: {
              // duration 동안 "초당 rate"로 로그인 유입을 분산합니다(실무형).
              // - 이 executor는 VU를 재사용하므로 "계정 유니크"를 위해 loginOnce에서 iterationInTest로 계정을 매핑합니다.
              executor: "constant-arrival-rate",
              rate: loginRate,
              timeUnit: "1s",
              duration,
              preAllocatedVUs: loginPreVUs,
              maxVUs: loginMaxVUs,
              exec: "loginOnce",
            },
          }
        : {
            per_user: {
              executor: "constant-vus",
              vus: users,
              duration,
              exec: "perUserLoop",
            },
          }),
  },
};

function zpad(n, width) {
  const s = String(n);
  if (s.length >= width) return s;
  return "0".repeat(width - s.length) + s;
}

function credsForVuId(vuIdInTest) {
  const suffix = zpad(vuIdInTest, userPad);
  return { username: `${userPrefix}${suffix}`, password: `${passPrefix}${suffix}` };
}

function credsForIndex1Based(i) {
  const suffix = zpad(i, userPad);
  return { username: `${userPrefix}${suffix}`, password: `${passPrefix}${suffix}` };
}

function headers(token) {
  const h = token ? { Authorization: `Bearer ${token}` } : {};
  if (host) h["Host"] = host;
  return h;
}

function sampleCount(ratePerSec) {
  // ratePerSec가 소수(예: 0.2/s)일 때도 "초당 기대치"를 만족하도록 샘플링합니다.
  // - 0.2/s이면, 각 1초마다 20% 확률로 1회를 수행(기대값 0.2)
  if (!isFinite(ratePerSec) || ratePerSec <= 0) return 0;
  const base = Math.floor(ratePerSec);
  const frac = ratePerSec - base;
  return base + (Math.random() < frac ? 1 : 0);
}

function login(username, password) {
  const payload = JSON.stringify({ username, password });
  const res = http.post(`${AUTH_BASE}${AUTH_LOGIN_PATH}`, payload, {
    timeout,
    headers: { "Content-Type": "application/json" },
  });
  check(res, { "login status is 200": (r) => r.status === 200 });
  if (res.status !== 200) return null;

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

function doGet(url, token) {
  return http.get(url, { timeout, headers: headers(token) });
}

function doWrite(token, state) {
  // employee WRITE(POST)
  // - 20% 확률로 update(employee_id 포함), 나머지는 create
  // - photoPct% 확률로 multipart 사진 첨부(이미지 리사이즈/IO 경로를 타게 하기 위함)
  const doUpdate = state.lastEmployeeId !== null && Math.random() < 0.2;

  const payload = {
    full_name: `k6-user-${state.vuId}-${state.iter}`,
    location: "seoul",
    job_title: "engineer",
    badges: "k6",
  };
  if (doUpdate) payload["employee_id"] = String(state.lastEmployeeId);
  if (Math.random() * 100 < photoPct) {
    payload["photo"] = http.file(tinyPngBytes, "photo.png", "image/png");
  }

  const res = http.post(empWriteUrl, payload, { timeout, headers: headers(token) });
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

export function loginOnce() {
  // auth_ramp에서는 VU 재사용으로 같은 계정이 여러 번 로그인할 수 있어서,
  // iterationInTest(1..N)를 계정 인덱스로 사용해 "유니크 로그인"에 가깝게 만듭니다.
  const idx =
    mode === "auth_ramp"
      ? exec.scenario.iterationInTest + 1
      : exec.vu.idInTest; // auth_spike는 VU=USERS라서 1..USERS와 동일

  // auth_ramp에서 duration 동안 rate를 주면 idx가 USERS를 넘어갈 수 있습니다.
  // - 예: USERS=5000인데 2분 동안 60/s로 주면 시도 횟수는 7200회 → 초과분은 skip
  if (idx > users) {
    sleep(0.01);
    return;
  }

  const { username, password } =
    mode === "auth_ramp" ? credsForIndex1Based(idx) : credsForVuId(idx);
  const token = login(username, password);
  // 성공/실패는 check로 집계
  if (!token) sleep(0.1);
}

export function perUserLoop() {
  // ===== 입력 검증(모드별 필수 URL) =====
  if (mode.startsWith("employee") || mode === "e2e") {
    if (!empGetUrl && (mode === "employee_get" || mode === "e2e")) {
      throw new Error("EMP_GET_URL is required for employee_get/e2e");
    }
    if (!empWriteUrl && (mode === "employee_write" || mode === "e2e")) {
      throw new Error("EMP_WRITE_URL is required for employee_write/e2e");
    }
    if (mode === "employee_write" && postThenGetPct > 0 && !empGetUrl) {
      throw new Error("EMP_GET_URL is required when POST_THEN_GET_PCT > 0 in employee_write");
    }
  }

  // ===== 이 VU가 담당할 계정 결정 =====
  // - constant-vus 기반 모드에서는 exec.vu.idInTest가 "이 VU의 고정 번호"로 동작합니다.
  // - 분산 실행에서도 idInTest는 전체 테스트 기준으로 유니크합니다.
  const vuId = exec.vu.idInTest; // 1..USERS
  const { username, password } = credsForVuId(vuId);

  const state = {
    vuId,
    iter: 0,
    token: null,
    lastEmployeeId: null,
  };

  // 로그인 필요 여부
  const needsLogin =
    mode === "e2e" ||
    mode === "employee_get" ||
    mode === "employee_write" ||
    (mode === "gateway_only" && gatewayNeedsAuth);

  if (needsLogin) {
    state.token = login(username, password);
    if (!state.token) {
      // 로그인 실패 시 이후 트래픽은 의미가 없어서 조용히 종료(실패율은 check로 집계)
      sleep(1);
      return;
    }
  }

  // 사용자당 초당 X회 요청을 맞추기 위한 1초 페이싱 루프
  while (true) {
    const start = Date.now();

    // ===== 모드에 따른 "이번 루프에서 쓸" URL/요청 수 결정 =====
    // 기본은 employee 기준(getUrl=EMP_GET_URL, gets/writes = GETS_PER_SEC/WRITES_PER_SEC)
    let effectiveGets = getsPerSec;
    let effectiveWrites = writesPerSec;
    let effectiveGetUrl = empGetUrl;

    if (mode === "employee_get") {
      effectiveWrites = 0;
      effectiveGetUrl = empGetUrl;
    } else if (mode === "employee_write") {
      effectiveGets = 0;
    } else if (mode === "gateway_only") {
      effectiveWrites = 0;
      effectiveGetUrl = gatewayUrl;
    }

    // ===== WRITE =====
    const writesThisSecond = sampleCount(effectiveWrites);
    for (let i = 0; i < writesThisSecond; i++) {
      doWrite(state.token, state);
    }

    // ===== GET (http.batch) =====
    // - getsThisSecond번 GET을 한꺼번에 묶어서 전송해, VU당 "1초 내 N회"를 효율적으로 수행합니다.
    const getsThisSecond = sampleCount(effectiveGets);
    if (getsThisSecond > 0) {
      const reqs = [];
      for (let i = 0; i < getsThisSecond; i++) {
        reqs.push(["GET", effectiveGetUrl, null, { timeout, headers: headers(state.token) }]);
      }
      const resps = http.batch(reqs);
      check(resps, { "get batch all 200": (arr) => arr.every((r) => r && r.status === 200) });
    }

    // ===== WRITE 직후 새로고침 GET(옵션) =====
    if (postThenGetPct > 0 && Math.random() * 100 < postThenGetPct) {
      const r2 = doGet(effectiveGetUrl, state.token);
      check(r2, { "post->refresh get 200": (r) => r.status === 200 });
    }

    state.iter++;

    const elapsed = (Date.now() - start) / 1000;
    // 1초 루프를 유지해서 "사용자당 초당 X회" 페이싱을 만듭니다.
    // - 서버가 느리면 elapsed>1이 되어 sleep=0 → 목표치 못 미침(그 자체가 용량 한계 신호)
    sleep(Math.max(0, 1 - elapsed));
  }
}

