#!/usr/bin/env bash
# Cycles payment-svc through a sequence of chaos scenarios so the Datadog/
# groundcover dashboards and monitors have real error/latency data to react
# to, without hand-curling each stage. Relies on load-generator's existing
# steady traffic (1 req/sec) — this script only toggles chaos state, it
# doesn't generate load itself; payment-svc's chaos state is single-replica
# in-memory by design (see CLAUDE.md), so this is the whole surface there is.
#
# Safe to interrupt (Ctrl-C) at any point — always reverts to baseline on
# exit via a trap, so you can't accidentally leave chaos running.
#
# Usage:
#   ./scripts/chaos-load-test.sh
#   PHASE_SECONDS=360 ./scripts/chaos-load-test.sh   # longer phases, e.g. to
#                                                     # reliably cross monitors'
#                                                     # 5-minute rolling windows
set -euo pipefail

NAMESPACE="workshop"
SERVICE="payment-svc"
LOCAL_PORT="${LOCAL_PORT:-5099}"
PHASE_SECONDS="${PHASE_SECONDS:-360}"
BOOKEND_SECONDS="${BOOKEND_SECONDS:-30}"

PF_PID=""
cleanup() {
  echo
  echo "Reverting chaos to baseline..."
  curl -s -X POST "http://localhost:${LOCAL_PORT}/chaos" \
    -H 'Content-Type: application/json' \
    -d '{"latency_ms": 0, "error_rate": 0.0}' >/dev/null 2>&1 || true
  [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null || true
}
trap cleanup EXIT INT TERM

echo "Port-forwarding ${SERVICE} (localhost:${LOCAL_PORT})..."
kubectl port-forward -n "$NAMESPACE" "svc/${SERVICE}" "${LOCAL_PORT}:5000" \
  >/tmp/chaos-load-test-portforward.log 2>&1 &
PF_PID=$!
sleep 2

set_chaos() {
  local latency="$1" error_rate="$2" label="$3" duration="$4"
  echo
  echo "== ${label} == latency=${latency}ms error_rate=${error_rate} for ${duration}s"
  curl -s -X POST "http://localhost:${LOCAL_PORT}/chaos" \
    -H 'Content-Type: application/json' \
    -d "{\"latency_ms\": ${latency}, \"error_rate\": ${error_rate}}"
  echo
  sleep "$duration"
}

echo "Chaos load test starting — each phase runs ${PHASE_SECONDS}s"
echo "(set PHASE_SECONDS=<n> to change; 300s+ recommended so the workshop's"
echo "5-minute rolling-window monitors have time to actually cross threshold)"

set_chaos 0    0.0  "baseline"          "$BOOKEND_SECONDS"
set_chaos 800  0.0  "latency spike"     "$PHASE_SECONDS"
set_chaos 0    0.3  "error spike"       "$PHASE_SECONDS"
set_chaos 800  0.3  "latency + errors"  "$PHASE_SECONDS"
set_chaos 0    0.0  "recovery"          "$BOOKEND_SECONDS"

echo
echo "Done — chaos reverted to baseline."
