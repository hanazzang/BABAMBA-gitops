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
### nfs 공유폴더 설정
```
# nfs폴더가 위치해야 할 곳(예를들어 192.168.1.147)
sudo apt update
sudo apt install nfs-kernel-server
공유 폴더 생성: sudo mkdir -p /data/nfs/photo
권한 설정: sudo chown -R nobody:nogroup /data/nfs/photo (보안 정책에 따라 조정 필요)
Exports 설정: /etc/exports 파일 맨 아래에 다음 내용 추가:
/data/nfs/photo 192.168.1.0/24(rw,sync,no_subtree_check) (192.168.1.x 대역의 모든 노드에 읽기/쓰기 허용 설정)
설정 적용: sudo exportfs -ra
서비스 재시작: sudo systemctl restart nfs-kernel-server 

# 마운트해서 쓸 노드쪽
sudo apt install -y nfs-common
sudo mount -t nfs 192.168.1.147:/data/nfs/photo /mnt
```


### revision 일괄변경 - argocd에서 싱크안맞다면 이 부분부터 점검 
```
bash scripts/fix-argocd-revisions.sh hpa2 --apply
```

### 하드코딩된 ip 변수로 적용 
- ips.env 수정 후
```
bash scripts/ipctl.sh apply
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