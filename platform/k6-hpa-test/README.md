## platform/k6-hpa-test

HPA/KEDA 스케일링 검증을 위한 **k6 부하테스트 리소스**를 모아두는 디렉터리입니다.

- **이 디렉터리**: k6 스크립트(JS), ConfigMap 정의, TestRun 템플릿(YAML) — 즉 “무엇을 실행할지” 정의
- **실제 절차**(ArgoCD 일시정지, 시나리오 전환, Helm 반영, 계정 시드, 관찰, 원복): **`hpa-test/readme.md`** 및 **`hpa-test/testrun-guides/*.md`** 참고

포함 리소스:
- k6 스크립트: `k6-hpa-employee-multiid.js`, `k6-hpa-photo-only.js`
- Kustomize: `kustomization.yaml` → `k6` ns + `k6-hpa-test-scenario` ConfigMap
- TestRun 템플릿: `testrun-templates/*.yaml` (8종, 수동 apply용)

---

## 📦 파일별 역할

- **`kustomization.yaml`**
  - **역할**: `kubectl apply -k platform/k6-hpa-test` 시 적용되는 “준비 리소스” 정의
  - 적용 결과: `k6` 네임스페이스 + ConfigMap `k6-hpa-test-scenario` (위 두 JS 포함)
  - **참고**: TestRun은 여기 포함하지 않음. apply -k만으로는 부하가 실행되지 않고, 템플릿을 따로 apply 할 때만 실행됨

- **`k6-hpa-employee-multiid.js`**
  - **역할**: auth / employee / gateway 부하를 **한 파일에서 `TEST_MODE` ENV로 구분**하는 공통 시나리오. 각 TestRun 템플릿이 `-e TEST_MODE=...`로 모드를 지정해 사용
  - **모드**: `auth_spike`, `auth_ramp`, `employee_get`, `employee_write`, `e2e`, `gateway_only` (각 모드별 동작은 `hpa-test/readme.md`의 TestRun 템플릿 섹션 참고)
  - **계정**: users.csv 없이 VU 번호 기준 결정론 규칙(예: `k6_user_000001` / `k6_pass_000001`). auth DB에 **미리 존재**해야 하며, `hpa-test/seed-auth-users.sh`로 생성/확장

- **`k6-hpa-photo-only.js`**
  - **역할**: **로그인 없이** photo 경로만 단독 부하(GET/WRITE). `PHOTO_URL`로 대상 지정(기본: gateway `/photo/`). gateway 주소 vs photo 서비스 ClusterIP 전환 가능. 업로드 API가 다르면 `PHOTO_WRITE_PATH`, `PHOTO_FILE_FIELD` 등 ENV로 조정

- **`testrun-templates/*.yaml`**
  - **역할**: 필요할 때만 `kubectl apply -f`로 실행하는 **수동 실행용** TestRun 정의(8종). 템플릿별 목적/실행 요약은 아래 표 참고.
  - **arguments 수정 시**: `testrun-arguments-guide.md`에 작성 규칙·ENV 목록·템플릿별 참고가 정리되어 있음.

---

## 🔁 실행 흐름(이 디렉터리 기준)

**전체 절차**(ArgoCD 일시정지, 시나리오 전환, Helm 반영, 계정 시드, 원복 등)는 **`hpa-test/readme.md`**와 **`hpa-test/testrun-guides/*.md`**를 따르면 됩니다.

1. **준비(실행 아님)**  
   `kubectl apply -k platform/k6-hpa-test`  
   → `k6` ns 및 ConfigMap `k6-hpa-test-scenario` 생성/갱신

2. **실행**  
   `kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/<name>.yaml`  
   → apply 시점에 k6-operator가 runner 등을 띄우며 테스트 시작

3. **관찰 / 재실행**  
   - k6: `hpa-test/watch-k6-testrun.sh <testrun-name>`  
   - 스케일: `hpa-test/watch-app-scaling.sh <target> <hpa|keda>`  
   - 재실행: `kubectl -n k6 delete testrun <name> --ignore-not-found` 후 동일 템플릿 다시 apply


---

## 🎯 TestRun 템플릿(요약)

| 템플릿 | 목적 | 비고 |
|--------|------|------|
| `employee-auth-spike` | 동시 로그인 버스트 → auth/redis/db 흡수 확인 | `TEST_MODE=auth_spike` |
| `employee-auth-ramp-2m` | 로그인 유입 rate 분산(램프) → auth 스케일 확인 | `TEST_MODE=auth_ramp`, `LOGIN_RATE=42` 등 |
| `employee-get` | 로그인 후 GET만 반복 → KEDA(RPS) 반응 확인 | `TEST_MODE=employee_get` |
| `employee-write` | 로그인 후 WRITE만 반복 → HPA/DB 병목 확인 | `TEST_MODE=employee_write` |
| `employee-e2e` | 로그인 후 GET+WRITE 혼합 → E2E 용량/안정성 | `TEST_MODE=e2e` |
| `gateway-only` | 특정 URL GET 반복 → gateway 레이어 병목 확인 | `TEST_MODE=gateway_only`, 가벼운 URL 권장 |
| `photo-only` | photo 경로 GET 중심 부하 | `k6-hpa-photo-only.js`, 로그인 없음 |
| `photo-write` | photo 경로 WRITE(업로드) 중심 부하 | 동일 스크립트, `WRITES_PER_SEC` 등 |

템플릿별 **바로 따라 치는 커맨드**(시나리오/Helm/시드/관찰/원복)는 **`hpa-test/testrun-guides/testrun-<템플릿이름>.md`**를 참고하세요. (예: `testrun-employee-get.md`)

---

## 계정 전제(요약)

- **로그인을 쓰는 템플릿**(`employee-*`, `gateway-only`에서 `GATEWAY_NEEDS_AUTH=true`인 경우): auth DB에 `k6_user_000001`～`k6_user_<USERS>` 형식 계정이 **미리 있어야** 합니다. `hpa-test/seed-auth-users.sh`로 생성/확장.
- **`photo-only` / `photo-write`**: 로그인 없이 실행되므로 계정 시드 불필요.

예시: `USERS=1000 MODE=extend ./hpa-test/seed-auth-users.sh`  
자세한 옵션·절차는 `hpa-test/seed-auth-users.sh` 상단 주석 및 `hpa-test/testrun-guides/*.md` 참고.
