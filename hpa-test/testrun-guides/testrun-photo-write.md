## TestRun 가이드: `photo-write` (photo WRITE 중심)

### 목표
- photo 업로드/저장(WRITE) 중심 부하를 걸어 photo/gateway 병목 및 스케일링 반응을 관찰합니다.

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
kubectl -n k6 delete testrun photo-write --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/photo-write.yaml
```

### 관찰
```bash
./hpa-test/watch-k6-testrun.sh photo-write

./hpa-test/watch-app-scaling.sh photo hpa
./hpa-test/watch-app-scaling.sh photo keda

./hpa-test/watch-app-scaling.sh gateway hpa
./hpa-test/watch-app-scaling.sh gateway keda
```

### 재실행
```bash
kubectl -n k6 delete testrun photo-write --ignore-not-found
kubectl -n k6 apply -f platform/k6-hpa-test/testrun-templates/photo-write.yaml
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

---

## k6 시나리오/파라미터 설명

### 전체 목적
photo 업로드/저장(WRITE) 중심으로 단독 부하하여 photo/gateway의 병목과 스케일링 반응을 관찰합니다.

### 1) 설정/파라미터(템플릿 기본값)
- **k6 스크립트**: `platform/k6-hpa-test/k6-hpa-photo-only.js`
- **부하/시간**: `USERS=1000`, `DURATION=2m`, `TIMEOUT=10s`
- **WRITE 부하**: `WRITES_PER_SEC=0.1` (사용자당 초당 기대치, 소수 가능)
- **대상**:
  - `PHOTO_URL=http://service-gateway.gateway.svc.cluster.local/photo/`
  - `HOST_HEADER=api.yongun.shop`
- **WRITE 경로/폼 필드(스크립트 기본값)**:
  - `PHOTO_WRITE_PATH=upload`
  - `PHOTO_FILE_FIELD=file`
  - 프로젝트의 업로드 API가 다르면 위 값을 맞추거나 `PHOTO_WRITE_URL`로 완전한 URL을 직접 지정하세요.

> 값을 바꾸려면 `platform/k6-hpa-test/testrun-templates/photo-write.yaml`을 복사해서 숫자/URL만 수정 후 apply 하세요.

### 2) 동작 흐름
1. 각 VU는 1초 페이싱 루프에서 매초 `WRITES_PER_SEC` 기대치만큼 multipart 업로드(작은 PNG)를 수행합니다.
2. 이 템플릿은 인증/로그인을 사용하지 않습니다.

