# HPA/KEDA 3가지 시나리오 테스트 (Git push 없이, ArgoCD 일시 정지 후 로컬 적용)

이 문서는 onprem/dev에서 **HPA/KEDA 시나리오(0/1/2)** 를 바꿔가며,
**k6-operator `TestRun`** 으로 부하를 걸고 스케일링 반응을 관찰하는 절차를 정리합니다.

GitOps 전제:
- 이 레포는 `ApplicationSet(onprem-dev-apps)`가 Helm `valueFiles`로 `values.yaml` + `values-autoscaling.yaml`을 합쳐 배포합니다.
- 예시(employee):
  - `clusters/onprem/dev/apps/employee/values.yaml`
  - `clusters/onprem/dev/apps/employee/values-autoscaling.yaml` (시나리오 스위치 파일)

**Git push 없이** 로컬 변경을 반영하려면 테스트 동안만 ArgoCD 리컨실(특히 `selfHeal`)을 잠깐 멈추고,
로컬 `helm upgrade`로 직접 적용합니다.

---
## ✅ 이 디렉터리(`hpa-test/`)의 역할(요약)

`hpa-test/`는 **(1) 시나리오 전환(HPA/KEDA), (2) k6 TestRun 실행, (3) 관찰/비교**를 위한 운영자용 도구 모음입니다.
클러스터에 “영구 설치”를 추가하는 게 아니라, 로컬 values 수정/Helm 반영 및 TestRun 실행/관찰을 돕습니다.

---
## 📦 스크립트 각각의 역할

- **`set-autoscaling-scenario.sh`**
  - **역할**: `clusters/onprem/dev/.../values-autoscaling.yaml`의 스위치만 바꿔서 시나리오(0/1/2)를 적용
  - **특징**: employee는 `--employee-get`, `--employee-write`로 **GET/WRITE를 분리**해서 서로 다른 시나리오 적용 가능
  - **주의**: 이 스크립트는 **로컬 파일을 수정**합니다. 클러스터 반영은 각 차트에 `helm upgrade --install ... -f values.yaml -f values-autoscaling.yaml`로 별도 수행.

- **`seed-auth-users.sh`**
  - **역할**: k6가 로그인에 쓸 **결정론 계정(k6_user_000001..USERS)** 을 auth에 등록(없으면 생성/확장)
  - **특징**: users.csv/Secret 없이, k8s **Job(컨테이너에서 계산)** 로 `/auth/register`를 호출

- **`legacy/`**
  - **역할**: 이전 방식의 k6 실행 스크립트(단일 토큰/구형 분산 방식 등)
  - **현재**: k6-operator `TestRun` 템플릿 방식으로 전환하면서 **레거시로 분류**

- **관찰(watch)**
  - **`watch-k6-testrun.sh`**: k6 `TestRun` 진행(stage)/pods/jobs/events 관찰
  - **`watch-app-scaling.sh`**: auth/gateway/photo/employee(get/write) 대상별 스케일(HPA/KEDA)/workload/pods/events 관찰

---
## 🔁 실행 흐름(부하테스트 절차)

아래 흐름이 “실무적으로 가장 흔한” 반복 테스트 루프입니다.
템플릿별 상세 커맨드(시나리오/Helm/시드/관찰/원복)는 `hpa-test/testrun-guides/*.md`를 참고하세요.

1) **(선택) ArgoCD 리컨실 일시정지**
2) **스케일링 시나리오(0/1/2) 선택**
   - `set-autoscaling-scenario.sh`로 로컬 values 변경
   - `helm upgrade ... -f values.yaml -f values-autoscaling.yaml`로 클러스터 반영
3) **(필요 시) 계정 시드**
   - `seed-auth-users.sh`로 `k6_user_000001..USERS` 생성/확장
4) **k6 준비 + 실행**
   - 준비: `kubectl apply -k platform/k6-hpa-test` (k6 ns + ConfigMap)
   - 실행: `kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/<템플릿>.yaml`
5) **관찰/비교**
   - 대상 스케일: `watch-app-scaling.sh ...`
   - k6 실행: `watch-k6-testrun.sh <testrun>`
6) **재실행**
   - `kubectl -n k6 delete testrun <name> && kubectl -n k6 apply -f ...`
7) **테스트 종료 후 원복**
   - values-autoscaling.yaml 원복 + ArgoCD 재가동

---
## 🎯 TestRun 템플릿(무엇을 테스트하나)

`TestRun` 템플릿은 `platform/k6-hpa-test/testrun-templates/*.yaml`에 있습니다.
각 템플릿은 “목적이 1개”가 되도록 설계되어, 병목/스케일링 반응을 분리해 관찰하기 쉽습니다.

계정/로그인 전제(중요):
- `employee-*` 템플릿은 기본적으로 **로그인 후 트래픽**을 생성합니다(스크립트: `platform/k6-hpa-test/k6-hpa-employee-multiid.js`).
- 계정은 `k6_user_000001..USERS` 같은 **결정론 규칙**으로 계산되므로, 먼저 `seed-auth-users.sh`로 계정을 만들어두어야 로그인 성공률이 나옵니다.
- `photo-*` 템플릿은 로그인 없이 실행됩니다(스크립트: `platform/k6-hpa-test/k6-hpa-photo-only.js`).

- **`employee-auth-spike`**
  - **목적**: “동시 로그인 버스트”로 auth/redis/db가 순간 부하를 흡수하는지 확인
  - **무엇을 때리나**: auth의 로그인 API (`/auth/login`)
  - **실행**: `employee-auth-spike.yaml` apply (모드: `TEST_MODE=auth_spike`, 각 VU가 로그인 1회)

- **`employee-auth-ramp-2m`**
  - **목적**: “로그인 유입을 초당 rate로 분산”시켜 실무형 램프업에서 auth 스케일/안정성 확인
  - **무엇을 때리나**: auth의 로그인 API (`/auth/login`)
  - **실행**: `employee-auth-ramp-2m.yaml` apply (모드: `TEST_MODE=auth_ramp`, 예: `LOGIN_RATE=42`)

- **`employee-get`**
  - **목적**: employee GET-only로 **KEDA(RPS) 반응/안정성** 확인
  - **무엇을 때리나**: gateway 경유 employee GET (`EMP_GET_URL`)
  - **실행**: `employee-get.yaml` apply (모드: `TEST_MODE=employee_get`, 예: `GETS_PER_SEC=2`)

- **`employee-write`**
  - **목적**: employee WRITE-only로 **HPA(CPU/MEM)/DB 병목** 확인
  - **무엇을 때리나**: gateway 경유 employee WRITE (`EMP_WRITE_URL`, 일부는 photo multipart 포함 가능)
  - **실행**: `employee-write.yaml` apply (모드: `TEST_MODE=employee_write`, 예: `WRITES_PER_SEC=0.2`)

- **`employee-e2e`**
  - **목적**: gateway→auth→employee(+photo) “전체 경로” 용량/안정성 확인
  - **무엇을 때리나**: 로그인 + employee GET/WRITE 혼합 (옵션으로 WRITE 후 새로고침 GET 포함)
  - **실행**: `employee-e2e.yaml` apply (모드: `TEST_MODE=e2e`, 예: `GETS_PER_SEC=1`, `WRITES_PER_SEC=0.1`)

- **`gateway-only`**
  - **목적**: 특정 URL GET 반복으로 gateway 레이어(라우팅/프록시) 병목 확인
  - **무엇을 때리나**: `GATEWAY_URL` (가능한 한 가벼운 엔드포인트 권장)
  - **실행**: `gateway-only.yaml` apply (모드: `TEST_MODE=gateway_only`, 옵션: `GATEWAY_NEEDS_AUTH=true`면 로그인 수행)

- **`photo-only` / `photo-write`**
  - **목적**: photo 경로 단독(또는 거의 단독)으로 GET/WRITE 부하 확인
  - **무엇을 때리나**: `PHOTO_URL` (기본은 gateway의 `/photo/` 경로)
  - **실행**:
    - `photo-only.yaml`: GET 중심 (예: `GETS_PER_SEC=2`)
    - `photo-write.yaml`: WRITE 중심 (예: `WRITES_PER_SEC=0.1`, 업로드 경로/폼필드가 다르면 `PHOTO_WRITE_PATH`/`PHOTO_FILE_FIELD` 조정)

---
## 🧹 (중요) HPA/KEDA로 확장된 파드 “빠르게 정리(일시적 스케일 다운)”

부하를 주고 나면 HPA/KEDA 때문에 파드가 많이 늘어날 수 있습니다.  
**테스트가 끝났는데 파드를 빨리 줄이고 싶다면** 아래 중 하나를 선택하세요.

### A) (권장, Helm/GitOps에 안전) autoscaling을 끄고(시나리오 0) Helm으로 반영

핵심은 **HPA/ScaledObject를 비활성화한 뒤**, 차트의 기본 replicas(또는 rollout `spec.replicas`)로 돌아가게 하는 겁니다.

예시:
```bash
./hpa-test/set-autoscaling-scenario.sh --employee-get 0 --employee-write 0 --auth 0 --photo 0 --gateway 0
helm upgrade --install onprem-dev-employee ./charts/employee \
  -n employee --create-namespace \
  -f ./clusters/onprem/dev/apps/employee/values.yaml \
  -f ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml

helm upgrade --install onprem-dev-auth ./charts/auth \
  -n auth --create-namespace \
  -f ./clusters/onprem/dev/apps/auth/values.yaml \
  -f ./clusters/onprem/dev/apps/auth/values-autoscaling.yaml

helm upgrade --install onprem-dev-photo ./charts/photo \
  -n photo --create-namespace \
  -f ./clusters/onprem/dev/apps/photo/values.yaml \
  -f ./clusters/onprem/dev/apps/photo/values-autoscaling.yaml

helm upgrade --install onprem-dev-gateway ./platform/gateway \
  -n gateway --create-namespace \
  -f ./clusters/onprem/dev/platform/gateway/values.yaml \
  -f ./clusters/onprem/dev/platform/gateway/values-autoscaling.yaml
```

원래 운영 기본으로 되돌리기(로컬 파일 기준):
```bash
./hpa-test/set-autoscaling-scenario.sh --default
helm upgrade --install onprem-dev-auth ./charts/auth \
  -n auth --create-namespace \
  -f ./clusters/onprem/dev/apps/auth/values.yaml \
  -f ./clusters/onprem/dev/apps/auth/values-autoscaling.yaml

helm upgrade --install onprem-dev-employee ./charts/employee \
  -n employee --create-namespace \
  -f ./clusters/onprem/dev/apps/employee/values.yaml \
  -f ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml

helm upgrade --install onprem-dev-photo ./charts/photo \
  -n photo --create-namespace \
  -f ./clusters/onprem/dev/apps/photo/values.yaml \
  -f ./clusters/onprem/dev/apps/photo/values-autoscaling.yaml

helm upgrade --install onprem-dev-gateway ./platform/gateway \
  -n gateway --create-namespace \
  -f ./clusters/onprem/dev/platform/gateway/values.yaml \
  -f ./clusters/onprem/dev/platform/gateway/values-autoscaling.yaml
```

### B) (즉시/임시, 드리프트 주의) kubectl로 강제 스케일 다운

HPA/KEDA가 켜져 있으면 `kubectl scale`이 곧바로 다시 늘려버릴 수 있습니다.  
그래서 **(1) 스케일러를 먼저 지우고 → (2) workload를 scale**하는 순서가 필요합니다.

예시(employee GET):
```bash
# 1) 스케일러 제거(임시)
kubectl -n employee delete scaledobject employee-server-get --ignore-not-found
kubectl -n employee delete hpa employee-server-get --ignore-not-found

# 2) workload 스케일 다운(rollout 기준)
kubectl -n employee scale rollout employee-server-get --replicas=1
```

이 방식은 Helm/ArgoCD가 다시 리컨실하면 원복될 수 있으니,
**일시적 응급 조치**로만 쓰는 걸 권장합니다.

---
## 📘 템플릿별 실행 가이드(권장 진입점)

템플릿(8종: auth-spike/ramp, employee-get/write/e2e, gateway-only, photo-only/write)은
템플릿별로 **“바로 따라 치는 커맨드”**를 `hpa-test/testrun-guides/`에 분리해두었습니다.

아래 중 목적에 맞는 가이드 1개를 골라 그대로 실행하세요.

- `employee-auth-spike`: `hpa-test/testrun-guides/testrun-employee-auth-spike.md`
- `employee-auth-ramp-2m`: `hpa-test/testrun-guides/testrun-employee-auth-ramp-2m.md`
- `employee-get`: `hpa-test/testrun-guides/testrun-employee-get.md`
- `employee-write`: `hpa-test/testrun-guides/testrun-employee-write.md`
- `employee-e2e`: `hpa-test/testrun-guides/testrun-employee-e2e.md`
- `gateway-only`: `hpa-test/testrun-guides/testrun-gateway-only.md`
- `photo-only`: `hpa-test/testrun-guides/testrun-photo-only.md`
- `photo-write`: `hpa-test/testrun-guides/testrun-photo-write.md`

공통 관찰 스크립트:

```bash
./hpa-test/watch-k6-testrun.sh <testrun-name>
./hpa-test/watch-app-scaling.sh <auth|gateway|photo|employee-get|employee-write> <hpa|keda>
```

