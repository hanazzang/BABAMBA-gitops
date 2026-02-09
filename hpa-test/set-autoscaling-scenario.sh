#!/usr/bin/env bash
set -euo pipefail

# 전역 시나리오 스위치:
# - 0: HPA/KEDA 끔
# - 1: HPA(cpu/memory, metrics-server 기반) 켬, KEDA 끔
# - 2: KEDA(RPS/p95) 켬 + (가능 시) CPU/Memory 보조트리거 켬
#
# 사용법:
#   ./set-autoscaling-scenario.sh <0|1|2> [--auth] [--employee] [--photo] [--gateway]
#
# 예:
#   ./set-autoscaling-scenario.sh 0
#   ./set-autoscaling-scenario.sh 0 --employee
#   ./set-autoscaling-scenario.sh 2 --employee --gateway

scenario="${1:-}"
shift || true

if [[ -z "${scenario}" ]]; then
  echo "usage: $(basename "$0") <0|1|2> [--auth] [--employee] [--photo] [--gateway]" >&2
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

# ===== 대상 파싱 =====
TARGETS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --auth)     TARGETS+=("auth") ;;
    --employee) TARGETS+=("employee") ;;
    --photo)    TARGETS+=("photo") ;;
    --gateway)  TARGETS+=("gateway") ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

# 옵션 없으면 전체 적용
if [[ ${#TARGETS[@]} -eq 0 ]]; then
  TARGETS=("auth" "employee" "photo" "gateway")
fi

apply_app_switch() {
  local app="$1" # auth|employee|photo
  local dst="${repo_root}/clusters/onprem/dev/apps/${app}/values-autoscaling.yaml"

  case "${scenario}" in
    0)
      if [[ "${app}" == "employee" ]]; then
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
  maxReplicas: 30
  cpu:
    averageUtilization: 80
  memory:
    averageUtilization: 75
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
  enabled: false
EOF
      else
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
        write_file "${dst}" <<'EOF'
replicaCount: 2

resources:
  requests:
    cpu: "300m"
    memory: "512Mi"
  limits:
    cpu: "1000m"
    memory: "1024Mi"

autoscaling:
  enabled: true
  minReplicas: 2
  maxReplicas: 30
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
  local dst="${repo_root}/clusters/onprem/dev/platform/gateway/values-autoscaling.yaml"

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

# ===== 실행 =====
for target in "${TARGETS[@]}"; do
  case "${target}" in
    auth|employee|photo)
      apply_app_switch "${target}"
      ;;
    gateway)
      apply_gateway_switch
      ;;
  esac
done

echo
echo "next:"

