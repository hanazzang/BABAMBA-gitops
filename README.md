<pre>
gitops/
├── README.md
│
├── bootstrap/                          # 🚀 초기 진입점 (클러스터별 1회 적용)
│   ├── root-onprem-dev.yaml
│   ├── root-onprem-prod.yaml
│   └── root-cloud-prod.yaml
│
├── applications/                       # 🧱 고정 설치 (Application)
│   ├── onprem-dev/
│   │   ├── envoy-gateway.yaml
│   │   ├── redis.yaml
│   │   ├── vault.yaml
│   │   ├── cloudflared.yaml
│   │   ├── argocd-rollouts.yaml
│   │   ├── prometheus.yaml
│   │   ├── grafana.yaml
│   │   ├── loki.yaml
│   │   ├── fluentbit.yaml
│   │   └── k6.yaml
│   │
│   ├── onprem-prod/
│   │   ├── envoy-gateway.yaml
│   │   ├── redis.yaml
│   │   ├── vault.yaml
│   │   ├── cloudflared.yaml
│   │   ├── argocd-rollouts.yaml
│   │   ├── prometheus.yaml
│   │   ├── grafana.yaml
│   │   ├── loki.yaml
│   │   └── fluentbit.yaml
│   │
│   └── cloud-prod/
│       ├── envoy-gateway.yaml
│       ├── redis.yaml
│       ├── vault.yaml
│       ├── cloudflared.yaml
│       ├── argocd-rollouts.yaml
│       ├── prometheus.yaml
│       ├── grafana.yaml
│       ├── loki.yaml
│       ├── fluentbit.yaml
│       └── karpenter.yaml
│
├── applicationsets/                   # 🔁 반복 생성 (ApplicationSet)
│   ├── onprem-dev/
│   │   ├── apps.yaml
│   │   └── platform-resources.yaml
│   │
│   ├── onprem-prod/
│   │   ├── apps.yaml
│   │   └── platform-resources.yaml
│   │
│   └── cloud-prod/
│       ├── apps.yaml
│       └── platform-resources.yaml
│
├── platform/                          # 🧩 공통 운영 리소스 템플릿
│   ├── gateway-resources/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── gateways.yaml
│   │       └── httproutes.yaml
│   │
│   ├── observability-rules/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── prometheus-rules.yaml
│   │       └── alertmanager-config.yaml
│   │
│   ├── grafana-dashboards/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── dashboards-configmaps.yaml
│   │       └── datasources-configmaps.yaml
│   │
│   ├── cloudflared-resources/
│   │   ├── Chart.yaml
│   │   ├── values.yaml
│   │   └── templates/
│   │       ├── tunnel-ingress.yaml
│   │       └── config.yaml
│   │
│   └── k6-scenarios/
│       ├── Chart.yaml
│       ├── values.yaml
│       └── templates/
│           └── k6-job.yaml
│
├── charts/                            # 📦 내부 애플리케이션 Helm Chart
│   ├── auth/
│   ├── employee/
│   └── photo/
│
└── clusters/                          # 🧠 환경별 Source of Truth
    ├── onprem/
    │   ├── dev/
    │   │   ├── apps/
    │   │   └── platform/
    │   └── prod/
    │       ├── apps/
    │       └── platform/
    │
    └── cloud/
        └── prod/
            ├── apps/
            └── platform/
</pre>

### 모니터링을 위한 노드에 셋팅

```
kubectl label node eks-worker1 dedicated=monitoring-loki --overwrite
```

### revision 일괄변경
```
bash scripts/fix-argocd-revisions.sh hana --apply
```

### hpa 시나리오 테스트를 위한 sh 파일 : 각 앱/플랫폼의 values-scenario.yaml만 갱신
```
chmod +x ./scripts/set-autoscaling-scenario.sh

# HPA-0: HPA/KEDA off
./scripts/set-autoscaling-scenario.sh 0

# HPA-1: HPA(cpu/memory) on, KEDA off
./scripts/set-autoscaling-scenario.sh 1

# HPA-2: KEDA(RPS/p95) on (+ CPU/MEM 보조트리거는 values-autoscaling에서 직접)
./scripts/set-autoscaling-scenario.sh 2


git diff
git add .
git commit -m "set autoscaling scenario: 1"
git push
```