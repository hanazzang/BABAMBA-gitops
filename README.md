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
- 프로메테우스와 loki는 다른 노드에 셋팅되어야 합니다. 

```
kubectl label node eks-worker1 dedicated=monitoring  # 프로메테우스 특정노드에 고정
# kubectl taint node eks-worker1 dedicated=monitoring:NoSchedule # 해당 파드에 이후 다른파드 못들어옴.(기존의 파드를 쫓아내진 않음.)

kubectl label node eks-worker1 loki=monitoring-loki   # loki 특정노트에 고정


# 만약 라벨제거해야할 경우
kubectl label node eks-worker1 dedicated-
kubectl label node eks-worker1 loki-
```
