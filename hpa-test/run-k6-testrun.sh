#!/usr/bin/env bash
set -euo pipefail

# Apply a k6-operator TestRun YAML, then stream runner logs (k6 output) and print a summary tail.
#
# Why:
# - `kubectl apply -f ...` only prints "created/unchanged".
# - Actual k6 progress + summary are in runner Pod logs.
# - With cleanup=post, resources/logs can disappear quickly after completion.
#
# Usage:
#   ./hpa-test/run-k6-testrun.sh platform/k6-hpa-test/testrun-templates/employee-get.yaml
#
# Env:
#   NS_K6            default: k6
#   LOG_DIR          default: /tmp/k6-logs
#   LOG_TAIL         default: 120 (summary tail printed at end)
#   MAX_LOG_REQUESTS default: 20  (kubectl logs concurrency)

file="${1:-}"
if [[ -z "${file}" ]]; then
  echo "usage: $(basename "$0") <testrun-yaml-path>" >&2
  exit 2
fi
if [[ ! -f "${file}" ]]; then
  echo "[ERROR] file not found: ${file}" >&2
  exit 2
fi

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "[ERROR] required command not found: $1" >&2; exit 2; }; }
need_cmd kubectl

NS_K6="${NS_K6:-k6}"
LOG_DIR="${LOG_DIR:-/tmp/k6-logs}"
LOG_TAIL="${LOG_TAIL:-120}"
MAX_LOG_REQUESTS="${MAX_LOG_REQUESTS:-20}"

mkdir -p "${LOG_DIR}"

# Parse metadata.name from YAML (best-effort, no yq dependency).
name="$(
  awk '
    BEGIN { inMeta=0 }
    /^[[:space:]]*metadata:[[:space:]]*$/ { inMeta=1; next }
    inMeta && /^[^[:space:]]/ { inMeta=0 }
    inMeta && /^[[:space:]]*name:[[:space:]]*/ {
      gsub(/^[[:space:]]*name:[[:space:]]*/, "", $0)
      gsub(/[[:space:]]*#.*/, "", $0)
      gsub(/"/, "", $0)
      print $0
      exit
    }
  ' "${file}" | tr -d "\r"
)"
if [[ -z "${name}" ]]; then
  echo "[ERROR] failed to parse metadata.name from: ${file}" >&2
  exit 2
fi

log_file="${LOG_DIR}/${name}-$(date +%Y%m%d_%H%M%S).log"

echo "[INFO] apply: ${file}"
kubectl -n "${NS_K6}" apply -f "${file}"

# Ensure noisy output: some existing CRs might have paused/quiet set.
kubectl -n "${NS_K6}" patch testrun "${name}" --type=merge -p '{"spec":{"paused":false,"quiet":false}}' >/dev/null 2>&1 || true

echo "[INFO] follow logs: ns=${NS_K6} testrun=${name} (label k6_cr=${name})"
echo "[INFO] saving log to: ${log_file}"
echo

start_ts="$(date -Is)"

# Wait until runner pods exist, then stream logs. We stream in background so we can also poll stage.
(
  # Wait for at least 1 pod with the label.
  for _ in $(seq 1 60); do
    if kubectl -n "${NS_K6}" get pods -l "k6_cr=${name}" -o name 2>/dev/null | grep -q '^pod/'; then
      break
    fi
    sleep 1
  done

  # Stream logs from all runner pods (interleaved). Prefix helps identify which pod wrote a line.
  kubectl -n "${NS_K6}" logs -f -l "k6_cr=${name}" \
    --prefix=true \
    --max-log-requests="${MAX_LOG_REQUESTS}" \
    --since-time="${start_ts}" 2>&1 | tee -a "${log_file}"
) &
log_pid=$!

# Poll stage until the CR disappears (cleanup) or moves to finished.
stage="unknown"
for _ in $(seq 1 240); do
  if ! kubectl -n "${NS_K6}" get testrun "${name}" >/dev/null 2>&1; then
    stage="deleted"
    break
  fi
  stage="$(kubectl -n "${NS_K6}" get testrun "${name}" -o jsonpath='{.status.stage}' 2>/dev/null || echo unknown)"
  if [[ "${stage}" == "finished" || "${stage}" == "error" ]]; then
    break
  fi
  sleep 2
done

# Stop log follow (if still running).
kill "${log_pid}" >/dev/null 2>&1 || true
wait "${log_pid}" >/dev/null 2>&1 || true

echo
echo "=== RESULT (testrun=${name}) ==="
echo "stage=${stage}"
echo
echo "=== k6 summary (tail ${LOG_TAIL}) ==="
tail -n "${LOG_TAIL}" "${log_file}" || true
echo
echo "[INFO] done. full log: ${log_file}"

