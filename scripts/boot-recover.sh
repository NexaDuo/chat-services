#!/usr/bin/env bash
# =============================================================================
# boot-recover.sh — bring the whole stack back to healthy after a host/WSL
# reboot, with ZERO manual steps (issue #138).
#
# WHY: on 2026-07-07 a WSL/host reboot left production down for ~6h. The core
# containers (nexaduo-postgres-1, nexaduo-chatwoot-rails-1) did not come back
# healthy, `restart: unless-stopped` could not self-heal (containers had exited
# 127 / were not restarted after boot), and cloudflared stayed UP so the tunnel
# still answered and nothing alerted. Recovery only happened after a human ran
# `scripts/run-stack.sh up`. This script IS that human step, automated, and is
# wired to run at boot by `scripts/run-stack.sh install-cron` (a @reboot cron —
# works because /etc/wsl.conf has systemd=true — plus, best-effort, an
# /etc/wsl.conf [boot] command).
#
# It is safe to run any time: it only calls `run-stack.sh up`, which never passes
# `-v` and never deletes the SACRED nexaduo_postgres-data volume.
# =============================================================================
set -uo pipefail

# REPO_ROOT is normally this script's repo. BOOT_RECOVER_REPO_ROOT overrides it so
# the hook can drive a stack that lives in a different checkout (used in testing).
REPO_ROOT="${BOOT_RECOVER_REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
LOG_FILE="${BOOT_RECOVER_LOG:-${HOME}/nexaduo-local/boot-recover.log}"
MARKER="${BOOT_RECOVER_MARKER:-${HOME}/nexaduo-local/.last-boot-recover}"
DOCKER_WAIT_TRIES="${DOCKER_WAIT_TRIES:-60}"   # x5s = up to 5 min
HEALTH_WAIT_TRIES="${HEALTH_WAIT_TRIES:-60}"   # x5s = up to 5 min

mkdir -p "$(dirname "$LOG_FILE")" "$(dirname "$MARKER")" 2>/dev/null || true

ts()  { date -u +'%Y-%m-%dT%H:%M:%SZ'; }
log() { echo "[$(ts)] [boot-recover] $*" | tee -a "$LOG_FILE"; }

log "boot recovery starting (repo=$REPO_ROOT, user=$(id -un 2>/dev/null || echo '?'))"

# 1. Wait for the Docker daemon. After a WSL boot the Docker Desktop / WSL
#    integration daemon can lag behind the boot command, so retry.
docker_up=0
for i in $(seq 1 "$DOCKER_WAIT_TRIES"); do
  if docker info >/dev/null 2>&1; then
    log "docker daemon is up (attempt $i)"
    docker_up=1
    break
  fi
  log "waiting for docker daemon (attempt $i/${DOCKER_WAIT_TRIES})"
  sleep 5
done
if [[ "$docker_up" != "1" ]]; then
  log "FATAL: docker daemon never became available — cannot recover the stack"
  echo "$(ts) FAILED docker-daemon-unavailable" > "$MARKER"
  exit 1
fi

# 2. Bring the whole stack up (idempotent; no -v; postgres volume SACRED).
#    run-stack.sh up also reconciles the backup + boot-recovery cron.
log "running scripts/run-stack.sh up"
if "${REPO_ROOT}/scripts/run-stack.sh" up >>"$LOG_FILE" 2>&1; then
  log "run-stack.sh up completed"
else
  log "WARN: run-stack.sh up returned non-zero (continuing to health wait)"
fi

# 3. Confirm the core services actually came back healthy — do NOT declare
#    success on the `up` return alone (no premature success on async flows).
rails_status="missing"; pg_status="missing"
for i in $(seq 1 "$HEALTH_WAIT_TRIES"); do
  pg_status="$(docker inspect -f '{{.State.Health.Status}}' nexaduo-postgres-1 2>/dev/null || echo missing)"
  rails_status="$(docker inspect -f '{{.State.Health.Status}}' nexaduo-chatwoot-rails-1 2>/dev/null || echo missing)"
  [[ "$pg_status" == "healthy" && "$rails_status" == "healthy" ]] && break
  sleep 5
done
log "postgres=${pg_status} chatwoot-rails=${rails_status}"

if [[ "$pg_status" == "healthy" && "$rails_status" == "healthy" ]]; then
  log "boot recovery SUCCEEDED"
  echo "$(ts) OK postgres=${pg_status} chatwoot-rails=${rails_status}" > "$MARKER"
  exit 0
else
  log "boot recovery INCOMPLETE — postgres=${pg_status} chatwoot-rails=${rails_status}"
  echo "$(ts) INCOMPLETE postgres=${pg_status} chatwoot-rails=${rails_status}" > "$MARKER"
  exit 1
fi
