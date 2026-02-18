## TestRun 가이드: `employee-get` (employee GET-only)

### 목표
- 로그인 후 employee GET만 반복하여 **employee-get의 KEDA(RPS) 반응/안정성**을 봅니다.

### 한 번만 준비(최초 1회)
```bash
chmod +x hpa-test/*.sh
kubectl apply -k platform/k6-hpa-test
```

### (선택) ArgoCD 리컨실 일시정지
```bash
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
kubectl -n argocd scale deploy argocd-application-controller --replicas=0
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0
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

