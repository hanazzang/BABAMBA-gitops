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
touch "${log_file}"

echo "[INFO] apply: ${file}"
kubectl -n "${NS_K6}" apply -f "${file}"

# Ensure noisy output: some existing CRs might have paused/quiet set.
# NOTE: k6-operator TestRun CRD schema expects these fields as strings in some versions.
kubectl -n "${NS_K6}" patch testrun "${name}" --type=merge -p '{"spec":{"paused":"false","quiet":"false"}}' >/dev/null 2>&1 || true

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

  # Wait until pods are past ContainerCreating (phase becomes Running/Succeeded/Failed),
  # otherwise `kubectl logs` often fails with BadRequest (ContainerCreating/PodInitializing).
  for _ in $(seq 1 120); do
    phases="$(
      kubectl -n "${NS_K6}" get pods -l "k6_cr=${name}" \
        -o jsonpath='{range .items[*]}{.status.phase}{"\n"}{end}' 2>/dev/null || true
    )"
    if echo "${phases}" | grep -Eq '^(Running|Succeeded|Failed)$'; then
      break
    fi
    sleep 1
  done

  # Stream logs from all runner pods (interleaved). Prefix helps identify which pod wrote a line.
  # Retry on transient startup errors (e.g., ContainerCreating).
  while true; do
    set +e
    kubectl -n "${NS_K6}" logs -f -l "k6_cr=${name}" \
      --prefix=true \
      --max-log-requests="${MAX_LOG_REQUESTS}" \
      --since-time="${start_ts}" 2>&1 | tee -a "${log_file}"
    rc=${PIPESTATUS[0]}
    set -e

    [[ "${rc}" -eq 0 ]] && break

    last="$(tail -n 5 "${log_file}" 2>/dev/null || true)"
    if echo "${last}" | grep -Eqi 'ContainerCreating|PodInitializing|waiting to start|not found'; then
      sleep 2
      continue
    fi

    echo "[WARN] log stream exited unexpectedly (rc=${rc}); retrying in 2s..." >&2
    sleep 2
  done
) &
log_pid=$!

# Poll stage until the CR disappears (cleanup) or moves to finished.
stage="unknown"
last_seen_stage="unknown"
last_seen_stage_at=""
terminated_exit_codes=""
for _ in $(seq 1 240); do
  if ! kubectl -n "${NS_K6}" get testrun "${name}" >/dev/null 2>&1; then
    stage="deleted"
    break
  fi
  stage="$(kubectl -n "${NS_K6}" get testrun "${name}" -o jsonpath='{.status.stage}' 2>/dev/null || echo unknown)"
  last_seen_stage="${stage}"
  last_seen_stage_at="$(date -Is)"

  # Best-effort: capture any terminated container exit codes while pods still exist.
  # (We do NOT treat exitCode=0 alone as success unless stage/log also indicate completion.)
  terminated_exit_codes="$(
    kubectl -n "${NS_K6}" get pods -l "k6_cr=${name}" \
      -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.state.terminated.exitCode}{"\n"}{end}{end}' 2>/dev/null \
      | grep -E '^[0-9]+$' || true
  )"
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
echo "last_seen_stage=${last_seen_stage} ${last_seen_stage_at:+(at ${last_seen_stage_at})}"
if [[ -n "${terminated_exit_codes}" ]]; then
  echo "terminated_exit_codes=$(echo "${terminated_exit_codes}" | tr '\n' ' ' | sed 's/[[:space:]]\\+$//')"
fi
echo
echo "=== k6 summary (tail ${LOG_TAIL}) ==="
if [[ -s "${log_file}" ]]; then
  tail -n "${LOG_TAIL}" "${log_file}" || true
else
  echo "[WARN] runner 로그가 캡처되지 않았습니다(파일이 비어있음)."
  echo "[WARN] TestRun이 즉시 종료/정리되었거나( cleanup=post ) runner Pod가 생성/기동 실패했을 수 있습니다."
  echo "[HINT] 아래로 원인 이벤트를 확인해보세요:"
  echo "  kubectl -n \"${NS_K6}\" get events --sort-by=.lastTimestamp | tail -n 30"
  echo "  kubectl -n \"${NS_K6}\" get pods -l \"k6_cr=${name}\" -owide"
fi
echo
echo "[INFO] done. full log: ${log_file}"

# Debug snapshot (helps when cleanup=post deletes resources quickly).
debug_file="${log_file%.log}.debug.txt"
{
  echo "=== DEBUG SNAPSHOT ==="
  echo "time=$(date -Is)"
  echo "ns=${NS_K6} testrun=${name}"
  echo "stage=${stage}"
  echo "last_seen_stage=${last_seen_stage} ${last_seen_stage_at:+(at ${last_seen_stage_at})}"
  echo
  echo "--- pods (label k6_cr=${name}) ---"
  kubectl -n "${NS_K6}" get pods -l "k6_cr=${name}" -owide 2>/dev/null || true
  echo
  echo "--- recent events (tail 50) ---"
  kubectl -n "${NS_K6}" get events --sort-by=.lastTimestamp 2>/dev/null | tail -n 50 || true
  echo
} >>"${debug_file}" 2>&1
echo "[INFO] debug snapshot: ${debug_file}"

# Final verdict + exit code:
# - 0: success, 1: failure, 2: unknown (insufficient evidence; usually due to very fast cleanup)
verdict="unknown"
exit_code=2
if [[ "${stage}" == "finished" || "${last_seen_stage}" == "finished" ]]; then
  verdict="success"
  exit_code=0
elif [[ "${stage}" == "error" || "${last_seen_stage}" == "error" ]]; then
  verdict="failure"
  exit_code=1
else
  # If we captured any non-zero exit code while pods existed, treat as failure.
  if echo "${terminated_exit_codes}" | grep -Eq '^[1-9]'; then
    verdict="failure"
    exit_code=1
  elif [[ -n "${terminated_exit_codes}" ]]; then
    # If we observed terminated exit codes and none are non-zero, treat as success.
    # This handles cases where k6-operator status.stage gets stuck (e.g., runner status service not ready),
    # but the underlying pods completed successfully.
    verdict="success"
    exit_code=0
  fi
fi

echo "[RESULT] verdict=${verdict} (exit_code=${exit_code})"
exit "${exit_code}"
