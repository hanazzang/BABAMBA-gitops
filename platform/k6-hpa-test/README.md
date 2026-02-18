## platform/k6-hpa-test

HPA/KEDA 스케일링 검증을 위한 k6 부하테스트 리소스(스크립트/ConfigMap/TestRun 등)를 모아두는 디렉터리입니다.

- 기존 `platform/k6/`: 일반 k6 예시/샘플(또는 기존 테스트) 용도
- 신규 `platform/k6-hpa-test/`: **HPA 테스트 시나리오 전용**(대량 동시 로그인/GET+WRITE 등)으로 분리

포함 리소스:
- k6 스크립트(JS): `k6-hpa-employee-multiid.js`
- k6 스크립트(JS): `k6-hpa-photo-only.js` (Photo 단독)
- ConfigMap 생성: `kustomization.yaml`의 `configMapGenerator` (중복 방지)
- 적용용 `kustomization.yaml`

---
## 📦 이 디렉터리의 역할(파일별)

- **`kustomization.yaml`**
  - **역할**: “준비 리소스”를 한 번에 적용하기 위한 Kustomize 엔트리
  - 적용되는 것:
    - `namespace-k6.yaml` → `k6` 네임스페이스
    - `configMapGenerator` → `k6-hpa-test-scenario` ConfigMap
      - `k6-hpa-employee-multiid.js`
      - `k6-hpa-photo-only.js`
  - **중요**: 여기에는 `TestRun`을 넣지 않습니다. (apply -k가 “실행”이 되지 않게 분리)

- **`k6-hpa-employee-multiid.js`**
  - **역할**: auth/employee/gateway 부하 시나리오(모드 기반)
  - 모드: `auth_spike`, `employee_get`, `employee_write`, `e2e`, `gateway_only`
  - **계정 방식**: users.csv 없이, 결정론 규칙(`k6_user_000001`…)로 계정 계산

- **`k6-hpa-photo-only.js`**
  - **역할**: photo 경로 단독 부하(GET/WRITE)
  - `PHOTO_URL`만 바꾸면 gateway 경유 vs photo service ClusterIP 단독을 쉽게 전환 가능

- **`testrun-templates/*.yaml`**
  - **역할**: 사람이 필요할 때만 `kubectl apply -f`로 실행하는 **수동 실행 버튼**
  - 템플릿별 목적은 아래 “TestRun 템플릿” 섹션 참고

---
## 🔁 실행 흐름(준비 → 실행 → 관찰)

1) **(필요 시) auth 계정 준비**
   - 이 레포는 `hpa-test/seed-auth-users.sh`로 `k6_user_000001..USERS`를 생성/확장할 수 있게 구성되어 있습니다.

2) **준비(실행 아님)**
   - `kubectl apply -k platform/k6-hpa-test`
   - 결과: `k6` 네임스페이스 + `k6-hpa-test-scenario` ConfigMap 생성/업데이트

3) **실행(원하는 TestRun 템플릿 1개 apply)**
   - `kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/<name>.yaml`
   - TestRun을 apply하는 순간 k6-operator가 runner/starter 등을 생성하며 테스트가 시작됩니다.

4) **관찰**
   - k6 실행: `hpa-test/watch-k6-testrun.sh <testrun-name>`
   - 스케일링: `hpa-test/watch-app-scaling.sh <target> <hpa|keda>`

5) **재실행**
```bash
kubectl -n k6 delete testrun <name> --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/<name>.yaml
```

---
## 🧹 HPA/KEDA로 확장된 파드 “일시 정리” (스케일 다운)

이 디렉터리의 `TestRun`은 **부하를 발생**시킬 뿐이고,  
파드 확장/축소는 각 서비스의 **HPA/KEDA 정책**에 의해 결정됩니다.

테스트가 끝났는데 파드가 많이 늘어난 상태를 빨리 정리하고 싶으면 보통 아래 중 하나를 씁니다.

- **(권장) Helm/GitOps에 안전한 방식**
  - `hpa-test/set-autoscaling-scenario.sh`로 autoscaling을 0(OFF) 또는 기본으로 되돌린 뒤
  - 각 차트에 `helm upgrade ... -f values.yaml -f values-autoscaling.yaml`로 반영

- **(즉시/임시) kubectl 강제 정리**
  - `scaledobject/hpa`를 삭제한 뒤 `rollout/deploy`를 `kubectl scale`로 내림
  - 이 방식은 Helm/ArgoCD 리컨실 시 다시 원복될 수 있어 “응급 조치”로만 권장

실제 커맨드 예시는 `hpa-test/readme.md`의 **“HPA/KEDA로 확장된 파드 빠르게 정리”** 섹션을 참고하세요.

---
## 🎯 TestRun 템플릿(목적/실행 방식)

- **`employee-auth-spike.yaml`**
  - **목적**: 동시 로그인 버스트(auth/redis/db) 확인
  - **실행**: `TEST_MODE=auth_spike`

- **`employee-auth-ramp-2m.yaml`**
  - **목적**: 2분 동안 로그인 분산(실무형 유입)으로 auth 흡수/스케일 반응 확인
  - **실행**: `TEST_MODE=auth_ramp` + `LOGIN_RATE=42` (≈ 2분에 5000 로그인)

- **`employee-get.yaml`**
  - **목적**: employee GET-only로 KEDA(RPS) 반응/안정성 확인
  - **실행**: `TEST_MODE=employee_get`

- **`employee-write.yaml`**
  - **목적**: employee WRITE-only로 HPA(CPU/MEM)/DB 병목 확인
  - **실행**: `TEST_MODE=employee_write`

- **`employee-e2e.yaml`**
  - **목적**: 전체 경로(gateway→auth→employee(+photo)) 용량/안정성 확인
  - **실행**: `TEST_MODE=e2e`

- **`gateway-only.yaml`**
  - **목적**: 특정 URL GET 반복으로 gateway 경로 병목 확인
  - **실행**: `TEST_MODE=gateway_only` + `GATEWAY_URL`을 가벼운 엔드포인트로 설정 권장
    - 권장 기본값: `http://service-gateway.gateway.svc.cluster.local/gateway-health` (http-echo)

- **`photo-only.yaml`**
  - **목적**: photo 경로 GET 중심 단독 부하
  - **실행**: `PHOTO_URL` + `GETS_PER_SEC`

- **`photo-write.yaml`**
  - **목적**: photo 경로 WRITE(업로드/저장) 중심 단독 부하
  - **실행**: `PHOTO_URL` + `WRITES_PER_SEC` (+ 필요 시 `PHOTO_WRITE_PATH`, `PHOTO_FILE_FIELD`)

---

### 실행(사람이 필요할 때만)
실제 부하 실행은 `TestRun`을 사람이 필요할 때만 적용(apply)하는 방식으로 수행합니다.

```bash
# (1) 준비(네임스페이스 + 시나리오 ConfigMap 생성) - 실행 아님
kubectl apply -k platform/k6-hpa-test

# (2) 실행(모드별 TestRun 템플릿 apply = 실행 시작)
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-auth-spike.yaml
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-auth-ramp-2m.yaml
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-get.yaml
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-write.yaml
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-e2e.yaml

# (선택) Photo-only
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/photo-only.yaml

# (선택) Photo-write (업로드/저장 부하)
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/photo-write.yaml

# (선택) Gateway-only
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/gateway-only.yaml
```

주요 파라미터:
- 템플릿은 “바로 apply 가능”한 고정값으로 제공됩니다.
- 값을 바꾸고 싶으면 템플릿 파일을 복사해서 숫자/URL만 수정한 뒤 apply 하세요.

재실행(같은 이름으로 다시 띄우고 싶을 때):
```bash
kubectl -n k6 delete testrun employee-get --ignore-not-found && kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-get.yaml
```

### (선택) 준비(수동, 실행 아님)
아래는 “준비만” 하고 싶을 때 사용하는 선택 옵션입니다.  
템플릿을 쓰는 방식에서는 보통 아래 준비를 먼저 수행합니다.

```bash
kubectl apply -k platform/k6-hpa-test
```

### 계정(아이디/비번) 전제(중요)
이 시나리오는 “동시에 로그인”이 핵심이라서, **계정이 사전에 존재**해야 합니다.

기본 규칙은 아래와 같습니다(커스터마이즈 가능):
- username: `USER_PREFIX + zero-pad(VU_ID)` (기본 `k6_user_000001`)
- password: `PASS_PREFIX + zero-pad(VU_ID)` (기본 `k6_pass_000001`)

즉, auth DB에 사용자 1..USERS가 미리 생성돼 있어야 로그인 성공합니다.
(이 프로젝트는 `hpa-test/seed-auth-users.sh`로 계정 생성/확장을 자동화할 수 있게 구성했습니다.)

예:
```bash
USERS=5000 MODE=extend ./hpa-test/seed-auth-users.sh
```

