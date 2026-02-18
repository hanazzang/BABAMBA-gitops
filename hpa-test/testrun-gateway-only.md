## TestRun 가이드: `gateway-only` (gateway 레이어 단독 GET)

### 목표
- 가능한 한 가벼운 엔드포인트로 gateway 레이어 병목/스케일링 반응을 관찰합니다.

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

### 시나리오 전환 + Helm 반영 (gateway)
```bash
# 권장: gateway=1(HPA). 필요하면 0 또는 2로 바꿔도 됨(2는 KEDA 사용 시)
./hpa-test/set-autoscaling-scenario.sh --gateway 1

helm upgrade --install onprem-dev-gateway ./platform/gateway \
  -n gateway --create-namespace \
  -f ./clusters/onprem/dev/platform/gateway/values.yaml \
  -f ./clusters/onprem/dev/platform/gateway/values-autoscaling.yaml
```

### 실행
```bash
kubectl -n k6 delete testrun gateway-only --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/gateway-only.yaml
```

### 관찰
```bash
./hpa-test/watch-k6-testrun.sh gateway-only

./hpa-test/watch-app-scaling.sh gateway hpa
./hpa-test/watch-app-scaling.sh gateway keda
```

### 재실행
```bash
kubectl -n k6 delete testrun gateway-only --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/gateway-only.yaml
```

### 종료/원복(권장)
```bash
./hpa-test/set-autoscaling-scenario.sh --default

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

