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
