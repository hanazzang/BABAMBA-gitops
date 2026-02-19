## TestRun 가이드: `employee-get` (employee GET-only)

### 목표
- 로그인 후 employee GET만 반복하여 **employee-get의 KEDA(RPS) 반응/안정성**을 봅니다.

### 0) 사전 준비
- `kubectl`, `helm`, `watch` 사용 가능해야 합니다.
- KEDA/Prometheus/metrics-server 등은 이미 클러스터에 설치되어 있다고 가정합니다.
- kube context가 onprem-dev를 가리키는지 확인:

```bash
kubectl config current-context
kubectl get ns | head
```

레포 루트로 이동:

```bash
cd "$(git rev-parse --show-toplevel)"
chmod +x hpa-test/*.sh
```

준비(실행 아님): k6 namespace + ConfigMap 생성/업데이트

```bash
kubectl apply -k platform/k6-hpa-test
```

---

### 1) (중요) ArgoCD “일시 정지” (리컨실 중단)
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

### 시나리오 전환 + Helm 반영 (employee-get + auth + gateway)
```bash
# 권장: employee-get=2(KEDA), auth=2(KEDA), gateway=1(HPA)
./hpa-test/set-autoscaling-scenario.sh --employee-get 2 --auth 2 --gateway 1

helm upgrade --install onprem-dev-employee ./charts/employee \
  -n employee --create-namespace \
  -f ./clusters/onprem/dev/apps/employee/values.yaml \
  -f ./clusters/onprem/dev/apps/employee/values-autoscaling.yaml

helm upgrade --install onprem-dev-auth ./charts/auth \
  -n auth --create-namespace \
  -f ./clusters/onprem/dev/apps/auth/values.yaml \
  -f ./clusters/onprem/dev/apps/auth/values-autoscaling.yaml

helm upgrade --install onprem-dev-gateway ./platform/gateway \
  -n gateway --create-namespace \
  -f ./clusters/onprem/dev/platform/gateway/values.yaml \
  -f ./clusters/onprem/dev/platform/gateway/values-autoscaling.yaml
```

### (중요) 계정 시드 (템플릿 기본 USERS=1000)
```bash
USERS=1000 MODE=extend ./hpa-test/seed-auth-users.sh
```

### 실행
```bash
kubectl -n k6 delete testrun employee-get --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-get.yaml
```

### 관찰
```bash
./hpa-test/watch-k6-testrun.sh employee-get

./hpa-test/watch-app-scaling.sh employee-get keda
./hpa-test/watch-app-scaling.sh employee-get hpa

./hpa-test/watch-app-scaling.sh auth keda
./hpa-test/watch-app-scaling.sh gateway hpa
```

### 재실행
```bash
kubectl -n k6 delete testrun employee-get --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-get.yaml
```

### 종료/원복(권장)
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

helm upgrade --install onprem-dev-gateway ./platform/gateway \
  -n gateway --create-namespace \
  -f ./clusters/onprem/dev/platform/gateway/values.yaml \
  -f ./clusters/onprem/dev/platform/gateway/values-autoscaling.yaml
```

### (선택) ArgoCD 재개
```bash
kubectl -n argocd scale deploy argocd-application-controller --replicas=1
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=1
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
```

---

## k6 시나리오/파라미터 설명

### 전체 목적
로그인 후 employee GET만 반복 호출하여 **GET 경로의 처리량/지연/스케일링(KEDA/RPS)** 반응을 관찰합니다.

### 1) 설정/파라미터(템플릿 기본값)
- **k6 스크립트**: `platform/k6-hpa-test/k6-hpa-employee-multiid.js`
- **모드**: `TEST_MODE=employee_get`
- **부하/시간**: `USERS=1000`, `DURATION=2m`, `TIMEOUT=10s`
- **GET 부하**: `GETS_PER_SEC=2` (사용자당 초당 기대치, 소수 가능)
- **POST→GET 혼합(옵션)**: `POST_THEN_GET_PCT=0`
- **auth**: `AUTH_BASE=...`, `AUTH_LOGIN_PATH=/auth/login`
- **라우팅**:
  - `HOST_HEADER=api.yongun.shop` (HTTPRoute 가상호스트 매칭용)
  - `EMP_GET_URL=http://service-gateway.gateway.svc.cluster.local/employee/employees`
- **계정 규칙**: `USER_PREFIX`, `PASS_PREFIX`, `USER_PAD` (seed 필요)

> 값을 바꾸려면 `platform/k6-hpa-test/testrun-templates/employee-get.yaml`을 복사해서 숫자/URL만 수정 후 apply 하세요.

### 2) 동작 흐름
1. 각 VU는 `exec.vu.idInTest(1..USERS)`로 **자기 계정**을 결정론적으로 계산합니다.
2. 시작 시 1회 `/auth/login`으로 JWT를 얻습니다(실패하면 해당 VU는 조용히 종료).
3. 이후 1초 페이싱 루프에서, 매초 `GETS_PER_SEC` 기대치만큼 `EMP_GET_URL`로 GET을 수행합니다.
   - 여러 GET은 `http.batch`로 묶어 전송합니다.

