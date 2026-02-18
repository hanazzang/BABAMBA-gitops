## TestRun 가이드: `photo-only` (photo GET 중심)

### 목표
- photo 경로(GET) 중심으로 부하를 걸어 photo/gateway 병목 및 스케일링 반응을 관찰합니다.

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

### 시나리오 전환 + Helm 반영 (photo + gateway)
```bash
# 권장: photo=1(HPA), gateway=1(HPA)
./hpa-test/set-autoscaling-scenario.sh --photo 1 --gateway 1

helm upgrade --install onprem-dev-photo ./charts/photo \
  -n photo --create-namespace \
  -f ./clusters/onprem/dev/apps/photo/values.yaml \
  -f ./clusters/onprem/dev/apps/photo/values-autoscaling.yaml

helm upgrade --install onprem-dev-gateway ./platform/gateway \
  -n gateway --create-namespace \
  -f ./clusters/onprem/dev/platform/gateway/values.yaml \
  -f ./clusters/onprem/dev/platform/gateway/values-autoscaling.yaml
```

### 실행
```bash
kubectl -n k6 delete testrun photo-only --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/photo-only.yaml
```

### 관찰
```bash
./hpa-test/watch-k6-testrun.sh photo-only

./hpa-test/watch-app-scaling.sh photo hpa
./hpa-test/watch-app-scaling.sh photo keda

./hpa-test/watch-app-scaling.sh gateway hpa
./hpa-test/watch-app-scaling.sh gateway keda
```

### 재실행
```bash
kubectl -n k6 delete testrun photo-only --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/photo-only.yaml
```

### 종료/원복(권장)
```bash
./hpa-test/set-autoscaling-scenario.sh --default

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

