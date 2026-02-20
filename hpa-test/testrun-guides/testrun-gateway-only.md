## TestRun 가이드: `gateway-only` (gateway 레이어 단독 GET)

### 목표
- 가능한 한 가벼운 엔드포인트로 gateway 레이어 병목/스케일링 반응을 관찰합니다.

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

### 시나리오 전환 + Helm 반영 (gateway)
```bash
# 권장: gateway=1(HPA). 필요하면 0 또는 2로 바꿔도 됨(2는 KEDA 사용 시)
./hpa-test/set-autoscaling-scenario.sh --gateway 1

helm upgrade --install onprem-dev-gateway ./platform/gateway \
  -n gateway --create-namespace \
  -f ./clusters/onprem/dev/platform/gateway/values.yaml \
  -f ./clusters/onprem/dev/platform/gateway/values-autoscaling.yaml
```

### (선택) 계정 시드 (GATEWAY_NEEDS_AUTH=true로 바꿀 때만 필요)
템플릿 기본값은 `GATEWAY_NEEDS_AUTH=false`라서 로그인 없이 실행됩니다.
보호 엔드포인트를 테스트하려면 템플릿에서 `GATEWAY_NEEDS_AUTH=true`로 바꾸고 아래를 실행하세요:

```bash
USERS=1000 MODE=extend ./hpa-test/seed-auth-users.sh
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

---

## k6 시나리오/파라미터 설명

### 전체 목적
가능한 한 가벼운 URL을 대상으로 GET만 반복해 **게이트웨이 레이어(라우팅/프록시) 한계**를 관찰합니다.

### 1) 설정/파라미터(템플릿 기본값)
- **k6 스크립트**: `platform/k6-hpa-test/k6-hpa-employee-multiid.js`
- **모드**: `TEST_MODE=gateway_only`
- **부하/시간**: `USERS=1000`, `DURATION=2m`, `TIMEOUT=10s`
- **GET 부하**: `GETS_PER_SEC=100` (사용자당 초당 기대치)
- **라우팅**:
  - `HOST_HEADER=api.yongun.shop`
  - `GATEWAY_URL=http://service-gateway.gateway.svc.cluster.local/gateway-health` (가벼운 엔드포인트 권장)
- **인증 필요 여부**: `GATEWAY_NEEDS_AUTH=false`
  - 보호 엔드포인트를 때리려면 `true`로 바꾸고, 계정 시드를 추가로 수행하세요.

> 값을 바꾸려면 `platform/k6-hpa-test/testrun-templates/gateway-only.yaml`을 복사해서 숫자/URL만 수정 후 apply 하세요.

### 2) 동작 흐름
1. `GATEWAY_NEEDS_AUTH=false`면 로그인 없이 바로 `GATEWAY_URL`로 GET을 반복합니다.
2. 1초 페이싱 루프에서 매초 `GETS_PER_SEC` 기대치만큼 GET을 수행합니다(backend 영향 최소화를 위해 가벼운 URL 권장).

