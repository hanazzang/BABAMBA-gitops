## TestRun 가이드: `employee-auth-spike` (동시 로그인 버스트)

### 목표
- auth 서비스에 **동시 로그인 버스트**를 걸어서 스케일링/병목(auth/redis/db)을 관찰합니다.

### 한 번만 준비(최초 1회)
```bash
# repo root에서 실행
chmod +x hpa-test/*.sh

# (준비 리소스) k6 namespace + ConfigMap 생성/업데이트 (실행 아님)
kubectl apply -k platform/k6-hpa-test
```

### (선택) ArgoCD 리컨실 일시정지
```bash
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
kubectl -n argocd scale deploy argocd-application-controller --replicas=0
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
```

### 시나리오 전환 + Helm 반영 (auth)
```bash
# auth를 KEDA 시나리오(2)로 (원하면 1 또는 0으로 바꿔도 됨)
./hpa-test/set-autoscaling-scenario.sh --auth 2

helm upgrade --install onprem-dev-auth ./charts/auth \
  -n auth --create-namespace \
  -f ./clusters/onprem/dev/apps/auth/values.yaml \
  -f ./clusters/onprem/dev/apps/auth/values-autoscaling.yaml
```

### (중요) 계정 시드 (템플릿 기본 USERS=1000)
```bash
USERS=1000 MODE=extend ./hpa-test/seed-auth-users.sh
```

### 실행 (TestRun apply)
```bash
kubectl -n k6 delete testrun employee-auth-spike --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-auth-spike.yaml
```

### 관찰
```bash
# k6 실행 상태(스테이지/파드/이벤트)
./hpa-test/watch-k6-testrun.sh employee-auth-spike

# auth 스케일링 관찰(HPA/KEDA 중 실제 켜진 쪽)
./hpa-test/watch-app-scaling.sh auth keda
./hpa-test/watch-app-scaling.sh auth hpa
```

### 재실행
```bash
kubectl -n k6 delete testrun employee-auth-spike --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-auth-spike.yaml
```

### 종료/원복(권장)
```bash
# 로컬 values-autoscaling.yaml을 운영 기본으로 되돌림
./hpa-test/set-autoscaling-scenario.sh --default

helm upgrade --install onprem-dev-auth ./charts/auth \
  -n auth --create-namespace \
  -f ./clusters/onprem/dev/apps/auth/values.yaml \
  -f ./clusters/onprem/dev/apps/auth/values-autoscaling.yaml
```

### (선택) ArgoCD 재개
```bash
# 원래 replicas가 1이 아니었다면 숫자만 원래대로 바꾸세요.
kubectl -n argocd scale deploy argocd-application-controller --replicas=1
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=1
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
```

