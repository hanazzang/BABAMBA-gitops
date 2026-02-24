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
LOG_TAIL="${LOG_TAIL:-40}"

watch -n "${INTERVAL}" "
echo \"=== TESTRUN (${NS_K6}/${name}) ===\"
kubectl -n \"${NS_K6}\" get testrun \"${name}\" -o wide 2>/dev/null || true
kubectl -n \"${NS_K6}\" get testrun \"${name}\" -o jsonpath='{.status.stage}' 2>/dev/null | sed 's/^/stage=/' || true
echo

echo \"=== JOBS/PODS (k6 ns) ===\"
kubectl -n \"${NS_K6}\" get jobs,pods -o wide 2>/dev/null | tail -n \"${POD_TAIL}\" || true
echo

echo \"=== RUNNER LOGS (tail) ===\"
# k6 출력은 runner 파드 로그에 남습니다. (cleanup=post면 완료 후 리소스/로그가 삭제될 수 있어 실행 중에 보는 걸 권장)
kubectl -n \"${NS_K6}\" logs -l \"k6_cr=${name}\" --tail=\"${LOG_TAIL}\" --max-log-requests=20 2>/dev/null || true
echo

echo \"=== RECENT EVENTS (k6 ns) ===\"
kubectl -n \"${NS_K6}\" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n \"${POD_TAIL}\" || true
"

