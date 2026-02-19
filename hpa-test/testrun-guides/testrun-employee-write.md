## TestRun 가이드: `employee-write` (employee WRITE-only)

### 목표
- 로그인 후 employee WRITE만 반복하여 **employee-write의 HPA(CPU/MEM) 반응**과 DB/Photo 연동 병목을 봅니다.

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

### 시나리오 전환 + Helm 반영 (employee-write + auth + gateway + photo)
```bash
# 권장: employee-write=1(HPA), auth=2(KEDA), gateway=1(HPA), photo=1(HPA)
./hpa-test/set-autoscaling-scenario.sh --employee-write 1 --auth 2 --gateway 1 --photo 1

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

### (중요) 계정 시드 (템플릿 기본 USERS=1000)
```bash
USERS=1000 MODE=extend ./hpa-test/seed-auth-users.sh
```

### 실행
```bash
kubectl -n k6 delete testrun employee-write --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-write.yaml
```

### 관찰
```bash
./hpa-test/watch-k6-testrun.sh employee-write

./hpa-test/watch-app-scaling.sh employee-write hpa
./hpa-test/watch-app-scaling.sh employee-write keda

./hpa-test/watch-app-scaling.sh auth keda
./hpa-test/watch-app-scaling.sh photo hpa
./hpa-test/watch-app-scaling.sh gateway hpa
```

### 재실행
```bash
kubectl -n k6 delete testrun employee-write --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-write.yaml
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

helm upgrade --install onprem-dev-photo ./charts/photo \
  -n photo --create-namespace \
  -f ./clusters/onprem/dev/apps/photo/values.yaml \
  -f ./clusters/onprem/dev/apps/photo/values-autoscaling.yaml

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
로그인 후 employee WRITE만 반복 호출하여 **WRITE 경로의 CPU/MEM/HPA 반응**과 DB/Photo 연동 병목을 관찰합니다.

### 1) 설정/파라미터(템플릿 기본값)
- **k6 스크립트**: `platform/k6-hpa-test/k6-hpa-employee-multiid.js`
- **모드**: `TEST_MODE=employee_write`
- **부하/시간**: `USERS=1000`, `DURATION=2m`, `TIMEOUT=10s`
- **WRITE 부하**: `WRITES_PER_SEC=0.2` (사용자당 초당 기대치; 0.2면 평균 5초에 1회)
- **사진 첨부 비율**: `PHOTO_PCT=70` (WRITE payload에 photo를 multipart로 첨부)
- **WRITE 후 새로고침 GET(옵션)**: `POST_THEN_GET_PCT=0`
- **auth**: `AUTH_BASE=...`, `AUTH_LOGIN_PATH=/auth/login`
- **라우팅**:
  - `HOST_HEADER=api.yongun.shop`
  - `EMP_WRITE_URL=http://service-gateway.gateway.svc.cluster.local/employee/employee`
- **계정 규칙**: `USER_PREFIX`, `PASS_PREFIX`, `USER_PAD` (seed 필요)

> 값을 바꾸려면 `platform/k6-hpa-test/testrun-templates/employee-write.yaml`을 복사해서 숫자/URL만 수정 후 apply 하세요.

### 2) 동작 흐름
1. 각 VU는 계정(결정론)으로 로그인해 JWT를 얻습니다.
2. 이후 1초 페이싱 루프에서 매초 `WRITES_PER_SEC` 기대치만큼 POST를 수행합니다.
3. 일부 WRITE는 tiny PNG를 multipart로 첨부해 “사진 처리 경로(리사이즈/IO)”를 타도록 합니다(`PHOTO_PCT`).
4. 필요하면(옵션) WRITE 성공 후 일부 비율로 GET을 추가로 호출할 수 있습니다(`POST_THEN_GET_PCT`).

