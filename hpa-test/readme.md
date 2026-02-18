# HPA/KEDA 3가지 시나리오 테스트 (Git push 없이, ArgoCD 일시 정지 후 로컬 적용)

이 레포는 `ApplicationSet(onprem-dev-apps)`가 Helm `valueFiles`로 아래를 합쳐 배포합니다.

- `clusters/onprem/dev/apps/employee/values.yaml`
- `clusters/onprem/dev/apps/employee/values-autoscaling.yaml`  ← 시나리오 스위치로 덮어쓰는 파일

 **Git push 없이**(로컬에서 `values-autoscaling.yaml` 덮어쓴 뒤) **ArgoCD 리컨실(자동복구)을 잠깐 멈추고** 3가지 시나리오를 반복 테스트할 수 있습니다.

 ArgoCD는 **원격 Git 상태**만 보므로, 테스트 중 로컬 파일 변경을 **Git push 없이** 클러스터에 반영하려면:
- 테스트 동안만 ArgoCD의 리컨실(특히 `selfHeal`)을 멈추고
- 로컬에서 `helm upgrade`로 직접 적용합니다.

---
“ArgoCD 일시정지 → 로컬 helm upgrade → 관찰/부하” 의 순서로 부하테스트는 진행됩니다. 
---

---
## ✅ 이 디렉터리(`hpa-test/`)의 역할(요약)

`hpa-test/`는 **(1) 스케일링 정책을 바꾸고(HPA/KEDA), (2) k6 TestRun을 실행하고, (3) 관찰/비교**하기 위한 “운영자용 도구 모음”입니다.

이 폴더의 스크립트들은 **클러스터에 뭔가를 설치**하는 도구가 아니라,
- (로컬) Helm values 파일을 바꾸거나
- (클러스터) k6 실행을 위한 Job/TestRun 등을 *생성*하거나
- 상태를 *관찰*하는 도구입니다.

---
## 📦 스크립트 각각의 역할

- **`set-autoscaling-scenario.sh`**
  - **역할**: `clusters/onprem/dev/.../values-autoscaling.yaml`의 스위치만 바꿔서 시나리오(0/1/2)를 적용
  - **특징**: employee는 `--employee-get`, `--employee-write`로 **GET/WRITE를 분리**해서 서로 다른 시나리오 적용 가능
  - **주의**: 이 스크립트는 **로컬 파일을 수정**합니다. 클러스터 반영은 `helm upgrade ... -f values.yaml -f values-autoscaling.yaml`로 별도 수행.

- **`seed-auth-users.sh`**
  - **역할**: k6가 로그인에 쓸 **결정론 계정(k6_user_000001..USERS)** 을 auth에 등록(없으면 생성/확장)
  - **특징**: users.csv/Secret 없이, k8s **Job(컨테이너에서 계산)** 로 `/auth/register`를 호출

- **`legacy_k6-employees-1id.sh` / `legacy_k6-employees-multiid.sh`**
  - **역할**: 이전 방식의 k6 실행 스크립트(단일 토큰/구형 분산 방식 등)
  - **현재**: k6-operator `TestRun` 템플릿 방식으로 전환하면서 **레거시로 분류**

- **관찰(watch)**
  - **`watch-k6-testrun.sh`**: k6 `TestRun` 진행(stage)/pods/jobs/events 관찰
  - **`watch-app-scaling.sh`**: auth/gateway/photo/employee(get/write) 대상별 스케일(HPA/KEDA)/workload/pods/events 관찰

---
## 🔁 실행 흐름(부하테스트 절차)

아래 흐름이 “실무적으로 가장 흔한” 반복 테스트 루프입니다.

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
## 🎯 TestRun 템플릿(목적/실행 방식)

`TestRun` 템플릿은 `platform/k6-hpa-test/testrun-templates/*.yaml`에 있습니다.
각 템플릿은 “목적이 1개”가 되도록 설계되어, 병목/스케일링 반응을 분리해 관찰하기 쉽습니다.

- **`employee-auth-spike`**
  - **목적**: “동시 로그인 버스트” 흡수(auth/redis/db 영향) 확인
  - **실행**: 모든 VU가 시작 직후 로그인 1회(`TEST_MODE=auth_spike`)

- **`employee-auth-ramp-2m`**
  - **목적**: “2분 동안 5000명 로그인”처럼 분산 유입(실무형)에서 auth 흡수/스케일 반응 확인
  - **실행**: `TEST_MODE=auth_ramp` + `LOGIN_RATE=42` (≈ 2분에 5000 로그인)

- **`employee-get`**
  - **목적**: employee GET-only → **KEDA(RPS) 반응/안정성** 확인
  - **실행**: 로그인 후 GET만 반복(`TEST_MODE=employee_get`)

- **`employee-write`**
  - **목적**: employee WRITE-only → **HPA(CPU/MEM)/DB 병목** 확인
  - **실행**: 로그인 후 WRITE만 반복(`TEST_MODE=employee_write`)

- **`employee-e2e`**
  - **목적**: gateway→auth→employee(+photo) “전체 경로” 용량/안정성 확인
  - **실행**: 로그인 후 GET+WRITE 혼합(`TEST_MODE=e2e`)

- **`gateway-only`**
  - **목적**: 특정 URL GET 반복으로 gateway 경로 관점 병목 확인
  - **실행**: `TEST_MODE=gateway_only` (옵션: auth 필요하면 `GATEWAY_NEEDS_AUTH=true`)

- **`photo-only` / `photo-write`**
  - **목적**: photo 경로 단독(또는 거의 단독)으로 GET/WRITE 부하 확인
  - **실행**: `k6-hpa-photo-only.js`가 `PHOTO_URL`로 GET/WRITE 반복

---
## 🧹 (중요) HPA/KEDA로 확장된 파드 “빠르게 정리(일시적 스케일 다운)”

부하를 주고 나면 HPA/KEDA 때문에 파드가 많이 늘어날 수 있습니다.  
**테스트가 끝났는데 파드를 빨리 줄이고 싶다면** 아래 중 하나를 선택하세요.

### A) (권장, Helm/GitOps에 안전) autoscaling을 끄고(시나리오 0) Helm으로 반영

핵심은 **HPA/ScaledObject를 비활성화한 뒤**, 차트의 기본 replicas(또는 rollout `spec.replicas`)로 돌아가게 하는 겁니다.

예시(employee GET/WRITE만 빠르게 정리):
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
## 튜토리얼 

#### 0) 사전 준비
- `kubectl`, `helm`, `watch` 사용 가능해야 합니다.
- KEDA/Prometheus/metrics-server 등은 이미 클러스터에 설치되어 있다고 가정합니다.
- kube context가 onprem-dev를 가리키는지 확인:

```bash
kubectl config current-context
kubectl get ns | head
```

레포 루트로 이동:

```bash
cd /home/seyeon/BABAMBA-gitops
chmod +x hpa-test/*.sh
```

---

#### 1) (중요) ArgoCD “일시 정지” (리컨실 중단)
ApplicationSet이 Application spec을 다시 덮어쓸 수 있으니, **application-controller + applicationset-controller** 둘 다 멈추는 걸 권장합니다.

```bash
# 현재 replicas 기록(나중에 복구용)
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller

# 리컨실 중단
kubectl -n argocd scale deploy argocd-application-controller --replicas=0
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0

# 확인
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
```

---

#### 2) 시나리오 전환(로컬 파일 덮어쓰기) + 로컬 Helm 반영

공통(로컬 반영 명령):

```bash
helm upgrade --install onprem-dev-employee ./charts/employee \
  -n employee --create-namespace \
  -f ./clusters/onprem/dev/apps/employee/values.yaml \
  -f ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml
```

- 시나리오 0: HPA/KEDA OFF

```bash
./hpa-test/set-autoscaling-scenario.sh 0 --employee
helm upgrade --install onprem-dev-employee ./charts/employee \
  -n employee --create-namespace \
  -f ./clusters/onprem/dev/apps/employee/values.yaml \
  -f ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml
```

- 시나리오 1: HPA(cpu/memory) ON, KEDA OFF

```bash
./hpa-test/set-autoscaling-scenario.sh 1 --employee
helm upgrade --install onprem-dev-employee ./charts/employee \
  -n employee --create-namespace \
  -f ./clusters/onprem/dev/apps/employee/values.yaml \
  -f ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml
```

- 시나리오 2: KEDA(RPS/p95) ON

```bash
./hpa-test/set-autoscaling-scenario.sh 2 --employee
helm upgrade --install onprem-dev-employee ./charts/employee \
  -n employee --create-namespace \
  -f ./clusters/onprem/dev/apps/employee/values.yaml \
  -f ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml
```

참고 확인:

```bash
kubectl -n employee get hpa,scaledobject
kubectl -n employee get rollout onprem-dev-employee-employee-server
```

---

#### 3) 상태 관찰 (watch)
- 시나리오 0:
```bash 
watch -n 2 '
echo "=== TOP PODS (CPU/MEM) ==="
kubectl -n employee top pods -l app.kubernetes.io/name=employee-server 2>/dev/null || echo "metrics-server 필요/미설치 가능"
echo
echo "=== PODS ==="
kubectl -n employee get pods -l app.kubernetes.io/name=employee-server -o wide 2>/dev/null || true
'
```

- 시나리오 1(HPA):

```bash
./hpa-test/watch-employee-scaling.sh hpa
```

- 시나리오 2(KEDA):

```bash
./hpa-test/watch-employee-scaling.sh keda
```

추가(템플릿 기반 k6 실행 관찰):

```bash
# k6-operator TestRun 진행상태/파드/이벤트를 한 화면에서 보기
./hpa-test/watch-k6-testrun.sh employee-get
./hpa-test/watch-k6-testrun.sh employee-write
./hpa-test/watch-k6-testrun.sh employee-e2e
./hpa-test/watch-k6-testrun.sh photo-write
```

추가(서비스별 스케일 관찰; TestRun 목적에 맞춰 선택):

```bash
# Auth 로그인 버스트(=employee-auth-spike) 관찰
./hpa-test/watch-app-scaling.sh auth hpa
./hpa-test/watch-app-scaling.sh auth keda

# Employee GET-only(=employee-get) 관찰
./hpa-test/watch-app-scaling.sh employee-get hpa
./hpa-test/watch-app-scaling.sh employee-get keda

# Employee WRITE-only(=employee-write) 관찰
./hpa-test/watch-app-scaling.sh employee-write hpa
./hpa-test/watch-app-scaling.sh employee-write keda

# Photo write-only(=photo-write) 관찰
./hpa-test/watch-app-scaling.sh photo hpa
./hpa-test/watch-app-scaling.sh photo keda

# Gateway-only(=gateway-only) 관찰
./hpa-test/watch-app-scaling.sh gateway hpa
./hpa-test/watch-app-scaling.sh gateway keda
```

---

#### 4) 부하 (k6)
부하주기 전 이전 이벤트/로그 깨끗하게 초기화하기. 

```bash
# (권장) "모드 기반" 부하: 컴포넌트 단독 → 마지막에 E2E
# - 필요 시 auth 계정은 seed-auth-users.sh가 자동으로 생성/확장합니다.
# - GETS_PER_SEC/WRITES_PER_SEC는 사용자당 초당 기대치(소수 가능)입니다.

# 1) Auth만: 동시 로그인 버스트(각 VU 1회 로그인)
USERS=5000 PARALLELISM=10 DURATION=2m TEST_MODE=auth_spike ./hpa-test/run-k6-hpa-test.sh

# 2) Employee-GET만: (기본) 사용자당 GET 2/s
USERS=5000 PARALLELISM=10 DURATION=5m TEST_MODE=employee_get ./hpa-test/run-k6-hpa-test.sh

# 3) Employee-WRITE만: (기본) 사용자당 WRITE 0.2/s (= 5초에 1회)
USERS=5000 PARALLELISM=10 DURATION=5m TEST_MODE=employee_write ./hpa-test/run-k6-hpa-test.sh

# 4) Gateway-only(선택): 로그인 없이 특정 URL만(보호 엔드포인트면 GATEWAY_NEEDS_AUTH=true)
USERS=5000 PARALLELISM=10 DURATION=5m TEST_MODE=gateway_only GATEWAY_URL=http://service-gateway.gateway.svc.cluster.local/employee/employees ./hpa-test/run-k6-hpa-test.sh

# 5) End-to-End: (기본) 사용자당 GET 1/s + WRITE 0.1/s
USERS=5000 PARALLELISM=10 DURATION=10m TEST_MODE=e2e ./hpa-test/run-k6-hpa-test.sh

# (옵션) 1개 계정(토큰 1개 공유) 기반으로 GET/WRITE만 빠르게 때려보고 싶을 때
RATE=200 DURATION=2m ./hpa-test/k6-employees-1id.sh
```

(필요시 값 변경: 각 스크립트 상단 ENV 참고)

---

#### 5) 테스트 종료 후 원복
로컬에 덮어쓴 파일을 Git 기준으로 되돌리고(권장), ArgoCD를 다시 켭니다.

```bash
git restore ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml

kubectl -n argocd scale deploy argocd-application-controller --replicas=1
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=1

kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
```

- 만약 원래 replicas가 1이 아니었다면, `kubectl -n argocd get deploy ...`로 원래 값에 맞춰 복구하세요.
```



---

## 1️⃣ `hpa` 모드 실행 예시

```bash
./watch-employee-scaling.sh hpa
```

```text
=== SCALERS (hpa) ===
NAME                                      REFERENCE                                           TARGETS         MINPODS   MAXPODS   REPLICAS   AGE
onprem-dev-employee-employee-server-hpa   Rollout/onprem-dev-employee-employee-server        92%/80%, 70%/75%  2         30        6          12m

NAME                    SCALETARGETKIND   SCALETARGETNAME   MIN   MAX   TRIGGERS   AGE
# (HPA 모드에서는 scaledobject가 없거나 비어 있음)

=== ROLLOUT ===
NAME                                   KIND     STATUS     AGE
onprem-dev-employee-employee-server    Rollout  Healthy    1h

=== PODS ===
NAME                                                         READY   STATUS    RESTARTS   AGE   IP             NODE
onprem-dev-employee-employee-server-6f7c9f4d7c-2q8sd        1/1     Running   0          3m    10.244.2.41    worker2
onprem-dev-employee-employee-server-6f7c9f4d7c-7bplw        1/1     Running   0          3m    10.244.1.23    worker1
onprem-dev-employee-employee-server-6f7c9f4d7c-k9m2x        1/1     Running   0          4m    10.244.3.18    worker3
onprem-dev-employee-employee-server-6f7c9f4d7c-ns9fp        1/1     Running   0          4m    10.244.2.39    worker2
onprem-dev-employee-employee-server-6f7c9f4d7c-qx5jw        1/1     Running   0          4m    10.244.1.25    worker1
onprem-dev-employee-employee-server-6f7c9f4d7c-vc9ml        1/1     Running   0          4m    10.244.3.21    worker3

=== EVENTS (onprem-dev-employee-employee-server-hpa) (latest) ===
Normal   SuccessfulRescale   28s   horizontal-pod-autoscaler  New size: 6; reason: cpu utilization above target
Normal   SuccessfulRescale   44s   horizontal-pod-autoscaler  New size: 5; reason: cpu utilization above target
Normal   ScalingReplicaSet   46s   deployment-controller      Scaled up replica set to 6
```

- 이 상태 의미

* CPU/메모리 기반 **HPA만 작동**
* TARGETS에 `%/80%` 같은 값 보임
* scale 이벤트 이유가 **cpu utilization**

---

## 2️⃣ `keda` 모드 실행 예시

```bash
./watch-employee-scaling.sh keda
```

```text
=== SCALERS (keda) ===
NAME                                   SCALETARGETKIND   SCALETARGETNAME                           MIN   MAX   TRIGGERS           AGE
onprem-dev-employee-employee-server    Rollout           onprem-dev-employee-employee-server      2     30    prometheus,rps     8m

NAME                                             REFERENCE                                           TARGETS           MINPODS   MAXPODS   REPLICAS   AGE
keda-hpa-onprem-dev-employee-employee-server      Rollout/onprem-dev-employee-employee-server        1200/800 (avg)    2         30        14         8m

=== ROLLOUT ===
NAME                                   KIND     STATUS     AGE
onprem-dev-employee-employee-server    Rollout  Healthy    1h

=== PODS ===
NAME                                                         READY   STATUS    RESTARTS   AGE   IP             NODE
onprem-dev-employee-employee-server-6f7c9f4d7c-0q9fw        1/1     Running   0          40s   10.244.3.55    worker3
onprem-dev-employee-employee-server-6f7c9f4d7c-2q8sd        1/1     Running   0          1m    10.244.2.41    worker2
onprem-dev-employee-employee-server-6f7c9f4d7c-3mzpt        1/1     Running   0          40s   10.244.1.71    worker1
onprem-dev-employee-employee-server-6f7c9f4d7c-7bplw        1/1     Running   0          1m    10.244.1.23    worker1
onprem-dev-employee-employee-server-6f7c9f4d7c-k9m2x        1/1     Running   0          1m    10.244.3.18    worker3
... (총 14 pods)

=== EVENTS (keda-hpa-onprem-dev-employee-employee-server) (latest) ===
Normal   SuccessfulRescale   6s    horizontal-pod-autoscaler  New size: 14; reason: External metric prometheus above target
Normal   SuccessfulRescale   21s   horizontal-pod-autoscaler  New size: 12; reason: External metric prometheus above target
Normal   KEDAScale           22s   keda-operator               ScaledObject triggered scaling
```

- 상태 의미

* **ScaledObject + KEDA가 만든 HPA** 둘 다 보임
* TARGETS가 `1200/800` 처럼 **RPS/latency 기반**
* 이벤트 이유가 `External metric` / `KEDAScale`

---


## k6 부하 스크립트에 대한 설명

### 전체 목적
**(1) auth에서 JWT를 자동으로 얻고 → (2) 그 토큰으로 gateway 경유 GET/WRITE 트래픽을 발생시키고(HTTP method로 get/write 라우팅 분리) → (3) 부하 전/후 + 진행 중에 pod 수 변화를 같이 찍는** “한 방” 부하 스크립트

---

### 1) 설정/파라미터(1~45)
- **셸 옵션**: `set -euo pipefail`로 에러에 엄격하게 동작(중간 실패 시 즉시 종료).
- **대상/계정 기본값 ENV**
  - `AUTH_BASE`: auth 서비스 주소(기본 `auth-server-stable.auth.svc:5001`)
  - `AUTH_USER`, `AUTH_PASS`: 로그인 계정
  - `EMP_URL`: (기본) GET 호출 URL(기본 `.../employee/employees`)
  - `EMP_GET_URL`: GET 호출 URL(기본: `EMP_URL`)
  - `EMP_WRITE_URL`: WRITE 호출 URL(기본: `EMP_GET_URL`에서 파생되어 `.../employee/employee`)
  - `HOST_HEADER`: HTTPRoute 매칭용 Host 헤더(가상호스트)
- **부하 파라미터 ENV**
  - `RATE`: (호환용) GET_RATE 기본값
  - `GET_RATE`: GET 시나리오의 초당 도착 요청수(기본: `RATE`)
  - `WRITE_RATE`: WRITE 시나리오의 초당 도착 요청수(기본: `0`)
  - `PHOTO_PCT`: WRITE 요청 중 사진(리사이즈) 포함 비율(%, 기본 `70`)
  - `POST_THEN_GET_PCT`: WRITE 성공 후 목록 확인 GET 비율(%, 기본 `30`)
  - `DURATION`, `PREALLOCATED_VUS`, `MAX_VUS`, `TIMEOUT`
- **쿠버네티스 관련**
  - `K6_IMAGE`, `NS_AUTH`, `NS_K6`, `NS_EMPLOYEE`
  - `EMP_POD_LABEL_SELECTOR`: employee pod 라벨 셀렉터
- **JWT 정규식**: 로그에서 토큰을 뽑기 위한 패턴(`header.payload.signature`)

---

### 2) 보조 함수: 스냅샷/간이 워처(46~65)
- `snapshot_k8s()`
  - 현재 시각 찍고
  - `employee` 네임스페이스의 `hpa,scaledobject` 상태와
  - employee pods 목록을 출력(부하 전/후 비교용)
- `watch_k8s()`
  - 5초마다 employee pods의 **전체 개수**와 **Ready 개수**를 요약 출력
  - “한 화면에 계속 스케일 변화가 보이게” 하려는 목적(터미널 스팸 최소화)

---

### 3) JWT 발급(67~96)
- `get-token`이라는 **임시 Pod**를 `auth` 네임스페이스에 띄워서(curl 이미지)
  - `/auth/login`에 username/password로 POST
- 응답을 파일로 받는 대신,
  - `kubectl logs get-token`에서 **JWT 정규식으로 토큰만 추출**
  - 최대 30초 재시도(파드 준비/로그 지연 대비)
- 토큰 얻으면 `get-token` Pod 삭제
- 토큰이 비면 실패 처리(부하를 걸 수 없으니 종료)

---

### 4) 부하 시작 전 상태 기록 + 단건 헬스체크(97~109)
- `snapshot_k8s`로 “부하 전” 스케일러/파드 상태를 찍음
- (기본) `EMP_GET_URL`에 **단건 curl**을 `k6` 네임스페이스에서 실행(`emp-check`)
  - 실패해도 전체 스크립트가 죽지 않게 `set +e … || true`
  - 여기서도 `Host` 헤더 + `Authorization: Bearer <TOKEN>`을 넣어 실제 호출 조건을 맞춤

---

### 5) k6 실행 + 진행 중 k8s 요약 출력(110~166)
- 기존 `k6-employees` Pod가 있으면 삭제(충돌 방지)
- 백그라운드로 `watch_k8s` 실행해서 pod ready 변화를 계속 출력
  - `trap`으로 스크립트 종료 시 워처 프로세스 정리
- `kubectl run k6-employees ... grafana/k6`로 k6 Pod를 띄우고,
  - 컨테이너 안에서 `/tmp/test.js`를 생성한 뒤 `k6 run` 실행
- k6 JS 로직(요지)
  - `constant-arrival-rate`를 **GET/WRITE 2개 시나리오로 분리**
    - GET: `EMP_GET_URL`로 GET
    - WRITE: `EMP_WRITE_URL`로 POST(FormData, 사진 포함 비율은 `PHOTO_PCT`)
  - WRITE는 성공 후 일부 비율로 “목록 확인 GET”을 추가 호출(`POST_THEN_GET_PCT`)
  - Host 헤더(옵션), Bearer 토큰 포함
  - `status 200` 체크 후 아주 짧게 sleep

---

### 6) 종료 후 정리 + 부하 후 상태 기록(164~168)
- 백그라운드 워처 종료(`kill WATCH_PID`)
- 다시 `snapshot_k8s`를 찍어서 “부하 후” 스케일러/파드 상태를 남김

---