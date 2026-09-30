#!/usr/bin/env bash
# Hourly host-only probe, independent of the Docker daemon (issues #197/#225).
# Alloy readiness/memory coverage is in the full health-check-all.sh run; this
# schedule intentionally checks only engine + backup freshness, as before.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_DIR="${HOME}/nexaduo-local"
# Before mkdir: on a fresh host this dir is the parent of the dumps (incl. .env archive).
umask 077
mkdir -p "$STATE_DIR"
exec >> "$STATE_DIR/health-check.log" 2>&1

finish() {
  local status=$?
  if (( status != 0 )); then
    printf '[%s] FAIL: scheduled host health check exited %s; see health-check.log\n' "$(date -Is)" "$status" > "$STATE_DIR/.health-last-fail.tmp"
    mv "$STATE_DIR/.health-last-fail.tmp" "$STATE_DIR/.health-last-fail"
    cat "$STATE_DIR/.health-last-fail"
  fi
}
trap finish EXIT
exec 9>"$STATE_DIR/.health-check.lock"
# A concurrent invocation must not clear another run's failure marker.
if flock -n -E 75 9; then
  :
else
  status=$?
  if [[ "$status" == 75 ]]; then
    echo "[$(date -Is)] SKIP: scheduled host health check already running"
    exit 0
  fi
  exit "$status"
fi
echo "[$(date -Is)] START: scheduled host health check"
# Bound hangs in Docker CLI; never allow a CI backup-skip flag in the schedule.
SKIP_BACKUP_CHECK=0 timeout --kill-after=10s 120s bash "$SCRIPT_DIR/health-check-all.sh" --host-only
rm -f "$STATE_DIR/.health-last-fail"
echo "[$(date -Is)] OK: scheduled host health check"
