#!/usr/bin/env bash
set -euo pipefail

# Stream scaling-related Events as a continuously growing log (append style).
#
# Why:
# - `kubectl get events | tail` (used in watch dashboards) only shows a snapshot and hides history.
# - Kubernetes also "combines" repeated events into a single Event object with an increasing count.
# - `--watch --output-watch-events` prints ADDED/MODIFIED updates so you can see events "stack up".
#
# Usage:
#   ./hpa-test/stream-scaling-events.sh <auth|gateway|photo|employee-get|employee-write> <hpa|keda>
#
# Env:
#   NS_* overrides (same as watch-app-scaling.sh)

target="${1:-}"
mode="${2:-}"
if [[ -z "${target}" || ( "${mode}" != "hpa" && "${mode}" != "keda" ) ]]; then
  echo "usage: $(basename "$0") <auth|gateway|photo|employee-get|employee-write> <hpa|keda>" >&2
  exit 2
fi

case "${target}" in
  auth)
    NS="${NS_AUTH:-auth}"
    HPA="${HPA_NAME:-auth-server-hpa}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-auth-server}"
    ;;
  gateway)
    NS="${NS_GATEWAY:-gateway}"
    HPA="${HPA_NAME:-envoy-gw-infra-hpa}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-envoy-gw-infra}"
    ;;
  photo)
    NS="${NS_PHOTO:-photo}"
    HPA="${HPA_NAME:-photo-server-hpa}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-photo-server}"
    ;;
  employee-get)
    NS="${NS_EMPLOYEE:-employee}"
    HPA="${HPA_NAME:-employee-server-get}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-employee-server-get}"
    ;;
  employee-write)
    NS="${NS_EMPLOYEE:-employee}"
    HPA="${HPA_NAME:-employee-server-write}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-employee-server-write}"
    ;;
  *)
    echo "[ERROR] unknown target: ${target}" >&2
    exit 2
    ;;
esac

EVENT_KIND="HorizontalPodAutoscaler"
if [[ "${mode}" == "hpa" ]]; then
  EVENT_OBJ="${HPA}"
else
  EVENT_OBJ="${KEDA_HPA}"
fi

echo "[INFO] streaming events: ns=${NS} kind=${EVENT_KIND} name=${EVENT_OBJ}"
echo "[INFO] stop with Ctrl+C"
echo

# Note: v1 Events often use deprecated* fields; they may show <none> depending on cluster version.
kubectl -n "${NS}" get events \
  --watch \
  --output-watch-events \
  --field-selector "involvedObject.kind=${EVENT_KIND},involvedObject.name=${EVENT_OBJ}" \
  -o custom-columns=WATCH:.type,TIME:.deprecatedLastTimestamp,COUNT:.deprecatedCount,REASON:.reason,OBJ:.involvedObject.name,MESSAGE:.message

