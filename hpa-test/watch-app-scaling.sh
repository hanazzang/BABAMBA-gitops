#!/usr/bin/env bash
set -euo pipefail

# Generic one-screen dashboard for HPA/KEDA scaling for a target.
#
# Usage:
#   ./hpa-test/watch-app-scaling.sh <auth|gateway|photo|employee-get|employee-write> <hpa|keda>
#
# Notes:
# - This is meant to match the current chart naming conventions (fullnameOverride based).
# - You can override names via env vars if your release differs.
#
# Env:
#   INTERVAL (default: 2)
#   EVENTS_TAIL (default: 12)

target="${1:-}"
mode="${2:-}"
if [[ -z "${target}" || ( "${mode}" != "hpa" && "${mode}" != "keda" ) ]]; then
  echo "usage: $(basename "$0") <auth|gateway|photo|employee-get|employee-write> <hpa|keda>" >&2
  exit 2
fi

INTERVAL="${INTERVAL:-2}"
EVENTS_TAIL="${EVENTS_TAIL:-12}"

# defaults that match current values.yaml fullnameOverride conventions
case "${target}" in
  auth)
    NS="${NS_AUTH:-auth}"
    APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=auth-server}"
    WORKLOAD="${WORKLOAD_NAME:-auth-server}"
    HPA="${HPA_NAME:-auth-server-hpa}"
    SCALEDOBJECT="${SCALEDOBJECT_NAME:-auth-server}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-auth-server}"
    ;;
  gateway)
    NS="${NS_GATEWAY:-gateway}"
    APP_LABEL="${APP_LABEL:-app=envoy-gw-dataplane}"
    WORKLOAD="${WORKLOAD_NAME:-envoy-gw-infra}"
    HPA="${HPA_NAME:-envoy-gw-infra-hpa}"
    SCALEDOBJECT="${SCALEDOBJECT_NAME:-envoy-gw-infra}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-envoy-gw-infra}"
    ;;
  photo)
    NS="${NS_PHOTO:-photo}"
    APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=photo-service}"
    WORKLOAD="${WORKLOAD_NAME:-photo-server}"
    HPA="${HPA_NAME:-photo-server-hpa}"
    SCALEDOBJECT="${SCALEDOBJECT_NAME:-photo-server}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-photo-server}"
    ;;
  employee-get)
    NS="${NS_EMPLOYEE:-employee}"
    APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=employee-server,traffic=get}"
    WORKLOAD="${WORKLOAD_NAME:-employee-server-get}"
    HPA="${HPA_NAME:-employee-server-get}"
    SCALEDOBJECT="${SCALEDOBJECT_NAME:-employee-server-get}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-employee-server-get}"
    ;;
  employee-write)
    NS="${NS_EMPLOYEE:-employee}"
    APP_LABEL="${APP_LABEL:-app.kubernetes.io/name=employee-server,traffic=write}"
    WORKLOAD="${WORKLOAD_NAME:-employee-server-write}"
    HPA="${HPA_NAME:-employee-server-write}"
    SCALEDOBJECT="${SCALEDOBJECT_NAME:-employee-server-write}"
    KEDA_HPA="${KEDA_HPA_NAME:-keda-hpa-employee-server-write}"
    ;;
  *)
    echo "[ERROR] unknown target: ${target}" >&2
    exit 2
    ;;
esac

if [[ "${mode}" == "hpa" ]]; then
  EVENT_KIND="HorizontalPodAutoscaler"
  EVENT_OBJ="${HPA}"
else
  EVENT_KIND="HorizontalPodAutoscaler"
  EVENT_OBJ="${KEDA_HPA}"
fi

watch -n "${INTERVAL}" "
echo \"=== TARGET (${target}) MODE (${mode}) ===\"
echo \"ns=${NS} workload=${WORKLOAD}\"
echo

echo \"=== SCALERS ===\"
if [[ \"${mode}\" == \"hpa\" ]]; then
  kubectl -n \"${NS}\" get hpa \"${HPA}\" -o wide 2>/dev/null || true
  kubectl -n \"${NS}\" get scaledobject 2>/dev/null || true
else
  kubectl -n \"${NS}\" get scaledobject \"${SCALEDOBJECT}\" -o wide 2>/dev/null || true
  kubectl -n \"${NS}\" get hpa \"${KEDA_HPA}\" -o wide 2>/dev/null || true
fi
echo

echo \"=== WORKLOAD ===\"
kubectl -n \"${NS}\" get rollout \"${WORKLOAD}\" 2>/dev/null || kubectl -n \"${NS}\" get deploy \"${WORKLOAD}\" 2>/dev/null || true
echo

echo \"=== PODS ===\"
kubectl -n \"${NS}\" get pods -l \"${APP_LABEL}\" -o wide 2>/dev/null || true
echo

echo \"=== EVENTS (${EVENT_OBJ}) (latest) ===\"
kubectl -n \"${NS}\" get events \\
  --field-selector involvedObject.kind=${EVENT_KIND},involvedObject.name=${EVENT_OBJ} \\
  --sort-by=.lastTimestamp 2>/dev/null | tail -n \"${EVENTS_TAIL}\" || true
"

