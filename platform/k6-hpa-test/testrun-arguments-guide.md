# TestRun arguments 작성 가이드

TestRun YAML의 `spec.arguments` 블록을 작성할 때 지켜야 할 규칙과, 사용 가능한 환경 변수(ENV) 목록·의미를 정리한 문서입니다.

---

## 공통 ENV (스크립트 공통)

| ENV | 의미 | 예시/비고 |
|-----|------|-----------|
| `USERS` | 동시 사용자 수(VU 상한 또는 계정 상한) | `1000` |
| `DURATION` | 테스트 총 시간 | `2m`, `5m` |
| `TIMEOUT` | HTTP 요청 타임아웃 | `10s` |
| `HOST_HEADER` | 요청 시 넣을 Host 헤더(게이트웨이 가상호스트 등) | `api.yongun.shop` |

---

## k6-hpa-employee-multiid.js 전용 ENV

### 모드·경로

| ENV | 의미 | 비고 |
|-----|------|------|
| `TEST_MODE` | 시나리오 모드 | `auth_spike`, `auth_ramp`, `employee_get`, `employee_write`, `e2e`, `gateway_only` |
| `AUTH_BASE` | auth 서버 베이스 URL | 예: `http://auth-server-stable.auth.svc:5001` |
| `AUTH_LOGIN_PATH` | 로그인 API 경로 | `/auth/login` |
| `EMP_GET_URL` | employee GET 경로(전체 URL) | gateway 경유 예: `http://.../employee/employees` |
| `EMP_WRITE_URL` | employee WRITE 경로(전체 URL) | gateway 경유 예: `http://.../employee/employee` |
| `GATEWAY_URL` | gateway_only 모드에서 때릴 URL | 가벼운 엔드포인트 권장 |
| `GATEWAY_NEEDS_AUTH` | gateway_only 시 로그인 여부 | `true` / `false` |

### 부하 강도(사용자당 초당)

| ENV | 의미 | 비고 |
|-----|------|------|
| `GETS_PER_SEC` | 사용자당 초당 GET 기대치(소수 가능) | 예: `5`, `2` |
| `WRITES_PER_SEC` | 사용자당 초당 WRITE 기대치(소수 가능) | 예: `0.2` (5초에 1회) |
| `PHOTO_PCT` | WRITE 시 photo 첨부 확률(%) | 예: `90` |
| `POST_THEN_GET_PCT` | WRITE 후 새로고침 GET 추가 확률(%) | e2e 등에서 사용 |

### auth_ramp 전용

| ENV | 의미 | 비고 |
|-----|------|------|
| `LOGIN_RATE` | 초당 로그인 시도 수 | 예: 2분에 1000명 ≒ `8.33`, 2분에 5000명 ≒ `42` |
| `LOGIN_PREALLOCATED_VUS` | 미리 확보해 둘 VU 풀 크기 | 예: `200` |
| `LOGIN_MAX_VUS` | 로그인 시나리오 최대 VU | 예: `1000` |

### 계정 규칙(결정론)

| ENV | 의미 | 비고 |
|-----|------|------|
| `USER_PREFIX` | 사용자명 접두사 | 기본 `k6_user_` |
| `PASS_PREFIX` | 비밀번호 접두사 | 기본 `k6_pass_` |
| `USER_PAD` | VU 번호 자리 수(제로패딩) | 기본 `6` → `k6_user_000001` |

---

## k6-hpa-photo-only.js 전용 ENV

| ENV | 의미 | 비고 |
|-----|------|------|
| `PHOTO_URL` | photo 부하 대상 베이스 URL | 기본: gateway의 `/photo/`. gateway 주소면 E2E에 가깝고, photo 서비스 ClusterIP면 단독 부하 |
| `GETS_PER_SEC` | 사용자당 초당 GET 기대치 | |
| `WRITES_PER_SEC` | 사용자당 초당 WRITE(업로드) 기대치 | |
| `PHOTO_GET_URL` | GET 전용 URL(지정 시 PHOTO_URL 무시) | 선택 |
| `PHOTO_WRITE_URL` | WRITE 전용 URL | 선택 |
| `PHOTO_GET_PATH` | GET 서브경로 | 기본 `health` |
| `PHOTO_WRITE_PATH` | 업로드 API 서브경로 | 기본 `upload`. **photo 서비스 업로드 API에 맞춰 조정** |
| `PHOTO_FILE_FIELD` | multipart 폼 필드명 | 기본 `file`. **API가 `photo` 등이면 조정** |

---

## 템플릿별 작성 참고

### employee-auth-spike

- `TEST_MODE=auth_spike`, `USERS`, `DURATION`, `TIMEOUT`, auth·계정 관련만 있으면 됨.
- 동시 로그인 버스트용이라 부하 강도(GETS_PER_SEC 등) 불필요.

### employee-auth-ramp-2m

- `TEST_MODE=auth_ramp` + `LOGIN_RATE`, `LOGIN_PREALLOCATED_VUS`, `LOGIN_MAX_VUS`.
- **참고**: 2분(120초) 동안 1000명 로그인 ≈ 초당 8.33 → `LOGIN_RATE=8.33`. 2분에 5000명이면 ≈ 42 → `LOGIN_RATE=42`.

### employee-get

- `TEST_MODE=employee_get` + `GETS_PER_SEC`, `EMP_GET_URL`, auth·계정 ENV.
- `GETS_PER_SEC`: 사용자당 초당 GET 기대치(소수 가능).

### employee-write

- `TEST_MODE=employee_write` + `WRITES_PER_SEC`, `PHOTO_PCT`, `POST_THEN_GET_PCT`, `EMP_WRITE_URL`, auth·계정 ENV.
- `POST_THEN_GET_PCT=0`: WRITE 후 새로고침 GET 없음. employee_get 모드에서 WRITE 후 GET을 쓰려면 `EMP_WRITE_URL` 등 필요.

### employee-e2e

- `TEST_MODE=e2e` + GET/WRITE 혼합용 `GETS_PER_SEC`, `WRITES_PER_SEC`, `PHOTO_PCT`, `POST_THEN_GET_PCT`, `EMP_GET_URL`, `EMP_WRITE_URL`, auth·계정 ENV.

### gateway-only

- **목적**: 게이트웨이 레이어(라우팅/프록시) 병목만 보는 것이므로, **가능한 한 가벼운 엔드포인트**를 쓰는 것이 좋습니다.
- `TEST_MODE=gateway_only` + `GATEWAY_URL`, `GATEWAY_NEEDS_AUTH`, `GETS_PER_SEC`.
- **권장**: platform/gateway 차트의 http-echo 같은 경로. 예: `GATEWAY_URL=.../gateway-health`.
- `GATEWAY_NEEDS_AUTH=false`면 로그인 없이 GET만 반복.

### photo-only / photo-write

- 스크립트: `k6-hpa-photo-only.js`. 로그인 없음.
- `PHOTO_URL`: 기본은 gateway의 `/photo/` 경로로 라우팅(실무 E2E에 가까움).
- **photo-write**에서 업로드 API가 다르면 아래를 추가·수정하세요.
  - `PHOTO_WRITE_PATH`: 업로드 경로(예: `upload`).
  - `PHOTO_FILE_FIELD`: multipart 필드명(예: `file` 또는 `photo`).

---

## 요약
- 스크립트별·모드별 ENV는 위 표와 템플릿별 참고를 따라 넣고, 기본값은 각 스크립트(`k6-hpa-employee-multiid.js`, `k6-hpa-photo-only.js`) 상단 주석·변수 초기화를 참고하면 됩니다.
