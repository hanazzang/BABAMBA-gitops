#!/usr/bin/env bash
set -euo pipefail

# 전역 시나리오 스위치:
# - 0: HPA/KEDA 끔
# - 1: HPA(cpu/memory, metrics-server 기반) 켬, KEDA 끔
# - 2: KEDA(RPS/p95) 켬 + (가능 시) CPU/Memory 보조트리거 켬
#
# 이 스크립트는 values-autoscaling.yaml(세부값)은 건드리지 않고,
# values-scenario.yaml(스위치 값)만 생성/갱신합니다.

scenario="${1:-}"
if [[ -z "${scenario}" ]]; then
  echo "usage: $(basename "$0") <0|1|2>" >&2
  exit 2
fi
if [[ "${scenario}" != "0" && "${scenario}" != "1" && "${scenario}" != "2" ]]; then
  echo "invalid scenario: ${scenario} (expected: 0|1|2)" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

write_file() {
  local dst="$1"
  local tmp="${dst}.tmp"
  mkdir -p "$(dirname "${dst}")"
  cat > "${tmp}"
  mv "${tmp}" "${dst}"
}

apply_app_switch() {
  local app="$1" # auth|employee|photo
  local dst="${repo_root}/clusters/onprem/dev/apps/${app}/values-scenario.yaml"

  case "${scenario}" in
    0)
      if [[ "${app}" == "employee" ]]; then
        # 시나리오 0: "체감 최악" (고정 1 pod + 낮은 CPU limit로 쉽게 포화)
        write_file "${dst}" <<'EOF'
replicaCount: 1

resources:
  requests:
    cpu: "50m"
    memory: "128Mi"
  limits:
    cpu: "150m"
    memory: "256Mi"

autoscaling:
  enabled: false
keda:
  enabled: false
EOF
      else
        # HPA/KEDA off (기본 replicas 유지)
        write_file "${dst}" <<'EOF'
autoscaling:
  enabled: false
keda:
  enabled: false
EOF
      fi
      ;;
    1)
      if [[ "${app}" == "employee" ]]; then
        # 시나리오 1: "개선" (HPA만, maxReplicas 제한 + 보수적 scaleUp)
        write_file "${dst}" <<'EOF'
replicaCount: 2

resources:
  requests:
    cpu: "150m"
    memory: "256Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 8
  cpu:
    averageUtilization: 80
  memory:
    averageUtilization: 75
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Pods
          value: 1
          periodSeconds: 30
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
      selectPolicy: Min

keda:
  enabled: false
EOF
      else
        # HPA on (cpu/memory), KEDA off
        write_file "${dst}" <<'EOF'
autoscaling:
  enabled: true
keda:
  enabled: false
EOF
      fi
      ;;
    2)
      if [[ "${app}" == "employee" ]]; then
        # 시나리오 2: "체감 최적" (KEDA: RPS/p95 기반 빠른 확장 + 충분한 리소스/최소 레플리카)
        # 목표: 동일 부하에서 p95 <= ~0.95s
        write_file "${dst}" <<'EOF'
replicaCount: 4

resources:
  requests:
    cpu: "300m"
    memory: "512Mi"
  limits:
    cpu: "1000m"
    memory: "1024Mi"

autoscaling:
  enabled: true
  minReplicas: 4
  maxReplicas: 30
  # KEDA에서도 HPA behavior로 반영됨 (charts/employee/templates/scaledobject.yaml)
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 0
      policies:
        - type: Percent
          value: 200
          periodSeconds: 15
        - type: Pods
          value: 6
          periodSeconds: 15
      selectPolicy: Max
    scaleDown:
      stabilizationWindowSeconds: 120
      policies:
        - type: Percent
          value: 50
          periodSeconds: 60
      selectPolicy: Min

keda:
  enabled: true
  pollingInterval: 5
  cooldownPeriod: 60
EOF
      else
        # KEDA on (RPS/p95). photo는 KEDA 템플릿이 없을 수 있어도 ignoreMissingValueFiles라 안전.
        write_file "${dst}" <<'EOF'
autoscaling:
  enabled: true
keda:
  enabled: true
EOF
      fi
      ;;
  esac

  echo "applied: scenario ${scenario} -> ${dst}"
}

apply_gateway_switch() {
  local dst="${repo_root}/clusters/onprem/dev/platform/gateway/values-scenario.yaml"

  case "${scenario}" in
    0)
      write_file "${dst}" <<'EOF'
autoscaling:
  enabled: false
keda:
  enabled: false
EOF
      ;;
    1)
      write_file "${dst}" <<'EOF'
autoscaling:
  enabled: true
keda:
  enabled: false
EOF
      ;;
    2)
      write_file "${dst}" <<'EOF'
autoscaling:
  enabled: true
keda:
  enabled: true
EOF
      ;;
  esac

  echo "applied: scenario ${scenario} -> ${dst}"
}

apply_app_switch "auth"
apply_app_switch "employee"
apply_app_switch "photo"
apply_gateway_switch

echo
echo "next:"
echo "  git diff"
echo "  git add . && git commit -m \"set autoscaling scenario: ${scenario}\" && git push"

