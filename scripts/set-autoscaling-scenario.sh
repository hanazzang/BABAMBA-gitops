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
      # HPA off
      write_file "${dst}" <<'EOF'
autoscaling:
  enabled: false
keda:
  enabled: false
EOF
      ;;
    1)
      # HPA on (cpu/memory), KEDA off
      write_file "${dst}" <<'EOF'
autoscaling:
  enabled: true
keda:
  enabled: false
EOF
      ;;
    2)
      # KEDA on (RPS/p95). photo는 KEDA 템플릿이 없을 수 있어도 ignoreMissingValueFiles라 안전.
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

