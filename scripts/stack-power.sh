#!/usr/bin/env bash
# stack-power.sh — easily power a NexaDuo stack VM on/off (the whole stack).
#
# The entire Docker Compose stack runs on a single VM, so stopping the VM
# halts every service AND stops the vCPU/RAM billing (the most expensive line
# item). Disks persist while stopped, so a stop/start is non-destructive — the
# Postgres data disk is prevent_destroy-guarded and snapshotted daily.
#
# Usage:
#   scripts/stack-power.sh <env> <start|stop|restart|status>
#     env: production | staging | default
#
# Examples:
#   scripts/stack-power.sh production stop      # power down prod (save cost)
#   scripts/stack-power.sh production start     # bring prod back up + wait SSH
#   scripts/stack-power.sh staging status
#
# Requires: gcloud authenticated with rights to start/stop the instance and
# read Secret Manager (zone is resolved from terraform_tfvars_<env>, the same
# source of truth the deploy pipeline uses).
set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
ENV="${1:?usage: stack-power.sh <env> <start|stop|restart|status>}"
ACTION="${2:?usage: stack-power.sh <env> <start|stop|restart|status>}"

case "$ENV" in
  production) VM="nexaduo-chat-services" ;;
  staging)    VM="nexaduo-chat-services-staging" ;;
  default)    VM="nexaduo-chat-services-default" ;;
  *) echo "unknown env '$ENV' (expected: production|staging|default)" >&2; exit 2 ;;
esac

# Resolve zone from the env's tfvars secret (single source of truth); fall back
# to the historical default zone if the secret can't be read.
ZONE="$(gcloud secrets versions access latest \
          --secret="terraform_tfvars_${ENV}" --project="$PROJECT_ID" 2>/dev/null \
        | grep -E '^\s*gcp_zone\s*=' | cut -d'"' -f2 || true)"
ZONE="${ZONE:-us-central1-b}"

status() {
  gcloud compute instances describe "$VM" --zone="$ZONE" --project="$PROJECT_ID" \
    --format='value(status)' 2>/dev/null || echo "NOT_FOUND"
}

case "$ACTION" in
  start)
    if [ "$(status)" = "RUNNING" ]; then echo "$VM already RUNNING."; exit 0; fi
    echo "Starting $VM ($ENV) in $ZONE ..."
    gcloud compute instances start "$VM" --zone="$ZONE" --project="$PROJECT_ID"
    echo "Waiting for SSH/containers to come up ..."
    for i in $(seq 1 30); do
      if gcloud compute ssh "$VM" --zone="$ZONE" --project="$PROJECT_ID" --tunnel-through-iap \
           --command="sudo docker ps --format '{{.Names}}' | head -n1" >/dev/null 2>&1; then
        echo "$VM is up and reachable."; exit 0
      fi
      echo "  ... ($i/30)"; sleep 10
    done
    echo "WARNING: $VM started but SSH not confirmed within timeout." >&2
    ;;
  stop)
    echo "Stopping $VM ($ENV) — the whole stack will go OFFLINE."
    gcloud compute instances stop "$VM" --zone="$ZONE" --project="$PROJECT_ID"
    echo "$VM stopped. vCPU/RAM billing paused; disks persist."
    ;;
  restart)
    echo "Resetting $VM ($ENV) ..."
    gcloud compute instances reset "$VM" --zone="$ZONE" --project="$PROJECT_ID"
    ;;
  status)
    echo "$VM ($ENV, $ZONE): $(status)"
    ;;
  *)
    echo "unknown action '$ACTION' (expected: start|stop|restart|status)" >&2; exit 2 ;;
esac
