#!/usr/bin/env bash
set -euo pipefail

# Watch k6-operator TestRun execution status.
#
# Usage:
#   ./hpa-test/watch-k6-testrun.sh <testrun-name>
#
# Examples:
#   ./hpa-test/watch-k6-testrun.sh employee-get
#   NS_K6=k6 INTERVAL=2 ./hpa-test/watch-k6-testrun.sh photo-write
#
# Env:
#   NS_K6     (default: k6)
#   INTERVAL  (default: 2) seconds
#   POD_TAIL  (default: 12) lines

name="${1:-}"
if [[ -z "${name}" ]]; then
  echo "usage: $(basename "$0") <testrun-name>" >&2
  exit 2
fi

NS_K6="${NS_K6:-k6}"
INTERVAL="${INTERVAL:-2}"
POD_TAIL="${POD_TAIL:-12}"

watch -n "${INTERVAL}" "
echo \"=== TESTRUN (${NS_K6}/${name}) ===\"
kubectl -n \"${NS_K6}\" get testrun \"${name}\" -o wide 2>/dev/null || true
kubectl -n \"${NS_K6}\" get testrun \"${name}\" -o jsonpath='{.status.stage}' 2>/dev/null | sed 's/^/stage=/' || true
echo

echo \"=== JOBS/PODS (k6 ns) ===\"
kubectl -n \"${NS_K6}\" get jobs,pods -o wide 2>/dev/null | tail -n \"${POD_TAIL}\" || true
echo

echo \"=== RECENT EVENTS (k6 ns) ===\"
kubectl -n \"${NS_K6}\" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n \"${POD_TAIL}\" || true
"

