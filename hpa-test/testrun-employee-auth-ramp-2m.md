## TestRun 가이드: `employee-auth-ramp-2m` (2분 로그인 램프업)

### 목표
- 2분 동안 로그인 요청을 분산 유입시키며 auth의 흡수/스케일 반응을 관찰합니다.

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

### 시나리오 전환 + Helm 반영 (auth)
```bash
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

### 실행
```bash
kubectl -n k6 delete testrun employee-auth-ramp-2m --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-auth-ramp-2m.yaml
```

### 관찰
```bash
./hpa-test/watch-k6-testrun.sh employee-auth-ramp-2m

./hpa-test/watch-app-scaling.sh auth keda
./hpa-test/watch-app-scaling.sh auth hpa
```

### 재실행
```bash
kubectl -n k6 delete testrun employee-auth-ramp-2m --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/employee-auth-ramp-2m.yaml
```

### 종료/원복(권장)
```bash
./hpa-test/set-autoscaling-scenario.sh --default

helm upgrade --install onprem-dev-auth ./charts/auth \
  -n auth --create-namespace \
  -f ./clusters/onprem/dev/apps/auth/values.yaml \
  -f ./clusters/onprem/dev/apps/auth/values-autoscaling.yaml
```

### (선택) ArgoCD 재개
```bash
kubectl -n argocd scale deploy argocd-application-controller --replicas=1
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=1
kubectl -n argocd get deploy argocd-application-controller argocd-applicationset-controller
```

