## TestRun 가이드: `employee-auth-spike` (동시 로그인 버스트)

### 목표
- auth 서비스에 **동시 로그인 버스트**를 걸어서 스케일링/병목(auth/redis/db)을 관찰합니다.

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
kubectl -n argocd get deploy argocd-applicationset-controller
kubectl -n argocd get deploy argocd-application-controller 2>/dev/null || kubectl -n argocd get sts argocd-application-controller

# 리컨실 중단
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=0
kubectl -n argocd scale deploy argocd-application-controller --replicas=0 2>/dev/null || kubectl -n argocd scale sts argocd-application-controller --replicas=0

# 확인
kubectl -n argocd get deploy argocd-applicationset-controller
kubectl -n argocd get deploy argocd-application-controller 2>/dev/null || kubectl -n argocd get sts argocd-application-controller
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
./hpa-test/run-k6-testrun.sh platform/k6-hpa-test/testrun-templates/employee-auth-spike.yaml
```

### 관찰
```bash
# k6 실행 상태(스테이지/파드/이벤트)
./hpa-test/watch-k6-testrun.sh employee-auth-spike

# (선택) runner 로그를 실시간으로 길게 보기(k6 콘솔 출력)
kubectl -n k6 logs -f -l k6_cr=employee-auth-spike --max-log-requests=20 --tail=50

# auth 스케일링 관찰(HPA/KEDA 중 실제 켜진 쪽)
./hpa-test/watch-app-scaling.sh auth keda
./hpa-test/watch-app-scaling.sh auth hpa
```

### 재실행
```bash
kubectl -n k6 delete testrun employee-auth-spike --ignore-not-found
./hpa-test/run-k6-testrun.sh platform/k6-hpa-test/testrun-templates/employee-auth-spike.yaml
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
kubectl -n argocd scale deploy argocd-applicationset-controller --replicas=1
kubectl -n argocd scale deploy argocd-application-controller --replicas=1 2>/dev/null || kubectl -n argocd scale sts argocd-application-controller --replicas=1
kubectl -n argocd get deploy argocd-applicationset-controller
kubectl -n argocd get deploy argocd-application-controller 2>/dev/null || kubectl -n argocd get sts argocd-application-controller
```

---

## k6 시나리오/파라미터 설명

### 전체 목적
**동시 로그인 버스트**를 만들어 auth(및 redis/db)의 흡수/스케일 반응을 관찰합니다.

### 1) 설정/파라미터(템플릿 기본값)
- **k6 스크립트**: `platform/k6-hpa-test/k6-hpa-employee-multiid.js` (ConfigMap: `k6-hpa-test-scenario`)
- **모드**: `TEST_MODE=auth_spike`
- **부하/시간**: `USERS=1000`, `DURATION=2m`, `TIMEOUT=10s`
- **auth**: `AUTH_BASE=http://auth-server-stable.auth.svc:5001`, `AUTH_LOGIN_PATH=/auth/login`
- **결정론 계정 규칙**: `USER_PREFIX=k6_user_`, `PASS_PREFIX=k6_pass_`, `USER_PAD=6`
  - 예: `k6_user_000001 / k6_pass_000001`

> 값을 바꾸려면 `platform/k6-hpa-test/testrun-templates/employee-auth-spike.yaml`을 복사해서 숫자/URL만 수정 후 apply 하세요.

### 2) 동작 흐름
1. k6-operator가 TestRun을 실행하면, runner가 분산 실행됩니다(`spec.parallelism`).
2. `auth_spike`는 **각 VU가 1회씩 로그인만 수행**합니다(버스트).
3. VU 번호(`exec.vu.idInTest`)로 계정을 계산해 `/auth/login`에 POST합니다.
4. 성공/실패는 k6 `check`로 집계되며, 이 템플릿은 로그인 이후 트래픽은 발생시키지 않습니다.

