#!/usr/bin/env bash
set -euo pipefail

# One-screen dashboard for employee scaling (HPA or KEDA).
#
# Usage:
#   ./scripts/watch-employee-scaling.sh hpa
#   ./scripts/watch-employee-scaling.sh keda
#
# Env:
#   NS_EMPLOYEE (default: employee)
#   APP_LABEL   (default: app.kubernetes.io/name=employee-server)
#   ROLLOUT_NAME (default: onprem-dev-employee-employee-server)
#   HPA_NAME    (default: onprem-dev-employee-employee-server-hpa)
#   KEDA_HPA_NAME (default: keda-hpa-onprem-dev-employee-employee-server)
#   SCALEDOBJECT_NAME (default: onprem-dev-employee-employee-server)
#   INTERVAL    (default: 2) seconds
#   EVENTS_TAIL (default: 12) lines

mode="${1:-}"
if [[ "${mode}" != "hpa" && "${mode}" != "keda" ]]; then
  echo "usage: $(basename "$0") <hpa|keda>" >&2
  exit 2
fi

NS_EMPLOYEE="${NS_EMPLOYEE:-employee}"
APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=employee-server}"
ROLLOUT_NAME="${ROLLOUT_NAME:-onprem-dev-employee-employee-server}"
HPA_NAME="${HPA_NAME:-onprem-dev-employee-employee-server-hpa}"
KEDA_HPA_NAME="${KEDA_HPA_NAME:-keda-hpa-onprem-dev-employee-employee-server}"
SCALEDOBJECT_NAME="${SCALEDOBJECT_NAME:-onprem-dev-employee-employee-server}"
INTERVAL="${INTERVAL:-2}"
EVENTS_TAIL="${EVENTS_TAIL:-12}"

if [[ "${mode}" == "hpa" ]]; then
  EVENT_KIND="HorizontalPodAutoscaler"
  EVENT_OBJ="${HPA_NAME}"
else
  EVENT_KIND="HorizontalPodAutoscaler"
  EVENT_OBJ="${KEDA_HPA_NAME}"
fi

watch -n "${INTERVAL}" "
echo \"=== SCALERS (${mode}) ===\"
if [[ \"${mode}\" == \"hpa\" ]]; then
  kubectl -n \"${NS_EMPLOYEE}\" get hpa \"${HPA_NAME}\" -o wide 2>/dev/null || true
  kubectl -n \"${NS_EMPLOYEE}\" get scaledobject 2>/dev/null || true
else
  kubectl -n \"${NS_EMPLOYEE}\" get scaledobject \"${SCALEDOBJECT_NAME}\" -o wide 2>/dev/null || true
  kubectl -n \"${NS_EMPLOYEE}\" get hpa \"${KEDA_HPA_NAME}\" -o wide 2>/dev/null || true
fi

echo
echo \"=== ROLLOUT ===\"
kubectl -n \"${NS_EMPLOYEE}\" get rollout \"${ROLLOUT_NAME}\" 2>/dev/null || true

echo
echo \"=== PODS ===\"
kubectl -n \"${NS_EMPLOYEE}\" get pods -l \"${APP_LABEL}\" -o wide 2>/dev/null || true

echo
echo \"=== EVENTS (${EVENT_OBJ}) (latest) ===\"
kubectl -n \"${NS_EMPLOYEE}\" get events \\
  --field-selector involvedObject.kind=${EVENT_KIND},involvedObject.name=${EVENT_OBJ} \\
  --sort-by=.lastTimestamp 2>/dev/null | tail -n \"${EVENTS_TAIL}\" || true
"

