## TestRun 가이드: `employee-auth-ramp-2m` (2분 로그인 램프업)

### 목표
- 2분 동안 로그인 요청을 분산 유입시키며 auth의 흡수/스케일 반응을 관찰합니다.

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

---

## k6 시나리오/파라미터 설명

### 전체 목적
`duration` 동안 로그인 유입을 **초당 rate로 분산**시켜 auth의 흡수/스케일 반응을 관찰합니다(실무형 유입).

### 1) 설정/파라미터(템플릿 기본값)
- **k6 스크립트**: `platform/k6-hpa-test/k6-hpa-employee-multiid.js`
- **모드**: `TEST_MODE=auth_ramp`
- **부하/시간**: `USERS=1000`, `DURATION=2m`, `TIMEOUT=10s`
- **로그인 유입(rate)**:
  - `LOGIN_RATE=42` (예: 2분(120s) 동안 약 5000회 시도 ≒ 41.7/s)
  - `LOGIN_PREALLOCATED_VUS=200`, `LOGIN_MAX_VUS=1000` (arrival-rate executor용 VU 풀)
- **auth**: `AUTH_BASE=...`, `AUTH_LOGIN_PATH=/auth/login`
- **결정론 계정 규칙**: `USER_PREFIX`, `PASS_PREFIX`, `USER_PAD`

> 값을 바꾸려면 `platform/k6-hpa-test/testrun-templates/employee-auth-ramp-2m.yaml`을 복사해서 숫자/URL만 수정 후 apply 하세요.

### 2) 동작 흐름
1. `auth_ramp`는 `constant-arrival-rate`로 **초당 LOGIN_RATE 만큼 로그인 시도**를 발생시킵니다.
2. 계정은 “시도 인덱스(전체 테스트 기준)”로 결정론적으로 매핑됩니다.
3. 시도 횟수가 `USERS`를 초과하면(예: rate가 너무 크면) 초과분은 스킵합니다.
4. 각 로그인 요청은 `/auth/login` POST이며, 성공/실패는 k6 `check`로 집계됩니다.

