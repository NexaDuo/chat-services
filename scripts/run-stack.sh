#!/usr/bin/env bash
# =============================================================================
# run-stack.sh — bring up / validate / back up the SUPPORTED PRODUCTION runtime.
#
# Since GCP was decommissioned (commit b02aa74) the full chat-services stack
# runs as Docker Compose on a single host and is served on the production
# domains (chat/dify/evolution/middleware/grafana.nexaduo.com) through the
# Cloudflare tunnel. This script is the versioned, reproducible bootstrap for
# that runtime — it replaces the GCP-bound deploy.yml pipeline. See AGENTS.md
# "Deployment Strategy" and issue #109.
#
# It supersedes the old, never-committed run-local.sh (which pulled secrets from
# GCP Secret Manager and dumps from GCS — both gone). Authoritative inputs are
# now host-local files that an operator restores from the pre-deletion export:
#   - ./.env            : real production secrets (gitignored). 67 keys incl.
#                         CHATWOOT_FRONTEND_URL=https://chat.nexaduo.com,
#                         TUNNEL_TOKEN (prod tunnel 1eea65b4), Azure/Chatwoot/
#                         Dify secret keys, etc. NOT the dev deploy/.env.
#   - $DUMPS_DIR        : pg_dump .sql.gz files to restore (prefer the last good
#                         set, *-2026-06-25-0300.sql.gz — see prod-data-loss memory).
# .env.production.example documents the required keys.
#
# Subcommands:
#   preflight   - verify .env + docker + network + (optional) dumps present
#   up          - bring up the full stack (no DB restore) — for a populated volume
#   restore     - restore DBs from $DUMPS_DIR onto the running Postgres
#   bootstrap   - preflight + up + restore (greenfield / clean rebuild)
#   validate    - smoke the real tunnel URLs + run Playwright against them
#   backup      - run scripts/backup-host.sh once
#   install-cron- install the 03:00 daily backup cron (host)
#   down        - stop the stack (DOES NOT delete volumes; SACRED Postgres data)
#   status      - docker compose ps
#
# SAFETY: `down` never passes -v. The Postgres Docker volume (nexaduo_postgres-data)
# is SACRED. The live host serves production traffic and is shared with other
# work — do NOT recreate postgres casually. See AGENTS.md Operational
# Non-Negotiables.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

ENV_FILE="${ENV_FILE:-${REPO_ROOT}/.env}"
DUMPS_DIR="${DUMPS_DIR:-${HOME}/nexaduo-local/dumps}"
NETWORK="${NETWORK:-nexaduo-network}"
COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-nexaduo}"
export COMPOSE_PROJECT_NAME

# Compose chain: app stacks + cross-stack overrides + the host-local proxy/tunnel.
COMPOSE_FILES=(
  -f deploy/docker-compose.shared.yml
  -f deploy/docker-compose.chatwoot.yml
  -f deploy/docker-compose.dify.yml
  -f deploy/docker-compose.nexaduo.yml
  -f docker-compose.yml
  -f deploy/docker-compose.localproxy.yml
)

# Domains served via the tunnel (for `validate`).
CHAT_URL="${CHATWOOT_URL:-https://chat.nexaduo.com}"
DIFY_URL="${DIFY_URL:-https://dify.nexaduo.com}"
DIFY_API_URL="${DIFY_API_URL:-https://dify.nexaduo.com}"
EVOLUTION_URL="${EVOLUTION_URL:-https://evolution.nexaduo.com}"
MIDDLEWARE_URL="${MIDDLEWARE_URL:-https://middleware.nexaduo.com}"
GRAFANA_URL="${GRAFANA_URL:-https://grafana.nexaduo.com}"

log()  { echo -e "\033[0;32m[run-stack]\033[0m $*"; }
warn() { echo -e "\033[0;33m[run-stack]\033[0m $*" >&2; }
die()  { echo -e "\033[0;31m[run-stack] ERROR:\033[0m $*" >&2; exit 1; }

dc() { docker compose --env-file "$ENV_FILE" "${COMPOSE_FILES[@]}" "$@"; }

preflight() {
  command -v docker >/dev/null || die "docker not found"
  docker compose version >/dev/null 2>&1 || die "docker compose v2 not found"
  [[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE — restore the production .env (see .env.production.example)"
  # Guard against the dev default leaking in: prod must serve the real domain.
  if grep -qE '^CHATWOOT_FRONTEND_URL=https?://(localhost|127\.0\.0\.1)' "$ENV_FILE"; then
    die "$ENV_FILE has a localhost CHATWOOT_FRONTEND_URL (dev default). Production must be https://chat.nexaduo.com."
  fi
  grep -qE '^TUNNEL_TOKEN=.' "$ENV_FILE" || warn "$ENV_FILE has no TUNNEL_TOKEN — the cloudflared tunnel will not register."
  docker network inspect "$NETWORK" >/dev/null 2>&1 || { log "creating docker network $NETWORK"; docker network create "$NETWORK"; }
  log "preflight OK (env=$ENV_FILE, network=$NETWORK)"
}

up() {
  preflight
  log "bringing up the stack (project=$COMPOSE_PROJECT_NAME)"
  dc up -d --remove-orphans
  dc ps
}

restore() {
  [[ -d "$DUMPS_DIR" ]] || die "DUMPS_DIR not found: $DUMPS_DIR"
  local pg; pg="$(docker ps --filter 'name=postgres' --filter 'ancestor=pgvector/pgvector:pg16' --format '{{.Names}}' | head -n1)"
  [[ -n "$pg" ]] || die "Postgres container not running — run '$0 up' first"
  log "restoring DBs from $DUMPS_DIR into $pg"
  # Sync the postgres password to the env (the named volume may have been init'd
  # with an older password; Postgres only honors POSTGRES_PASSWORD on first init).
  local pgpass; pgpass="$(grep -E '^POSTGRES_PASSWORD=' "$ENV_FILE" | head -1 | cut -d= -f2-)"
  if [[ -n "$pgpass" ]]; then
    docker exec -i "$pg" psql -U postgres -c "ALTER USER postgres PASSWORD '${pgpass}';" >/dev/null 2>&1 || \
      warn "could not ALTER postgres password (may already match)"
  fi
  shopt -s nullglob
  for dump in "$DUMPS_DIR"/*.sql.gz; do
    local db; db="$(basename "$dump" | sed -E 's/-[0-9]{4}-[0-9]{2}-[0-9]{2}.*//')"
    [[ "$db" =~ ^(postgres|template0|template1)$ ]] && continue
    log "  restoring $db <- $(basename "$dump")"
    docker exec -i "$pg" psql -U postgres -c "CREATE DATABASE \"$db\";" >/dev/null 2>&1 || true
    zcat "$dump" | docker exec -i "$pg" psql -U postgres -v ON_ERROR_STOP=0 -d "$db" >/dev/null
  done
  shopt -u nullglob
  log "restore complete. NOTE: pg_dump excludes Dify per-workspace RSA privkeys"
  warn "  and chatwoot-storage uploads (Docker volumes). If model-provider creds"
  warn "  show PrivkeyNotFoundError, restore the Docker volumes too (see AGENTS.md DR)."
}

bootstrap() { preflight; up; restore; log "bootstrap done — validate with: $0 validate"; }

validate() {
  log "smoke-testing the real tunnel URLs"
  local fail=0
  check() { local name="$1" url="$2"; local code; code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 "$url" || echo 000)";
            case "$code" in 2*|3*|4*) log "  OK   $name -> $code ($url)";; *) warn "  FAIL $name -> $code ($url)"; fail=1;; esac; }
  check chatwoot     "$CHAT_URL/"
  check dify-web     "$DIFY_URL/"
  check dify-api     "$DIFY_API_URL/console/api/setup"
  check evolution    "$EVOLUTION_URL/"
  check middleware   "$MIDDLEWARE_URL/health"
  check grafana      "$GRAFANA_URL/"
  [[ "$fail" -eq 0 ]] || die "smoke failed — see above before running Playwright"
  if [[ -d onboarding ]]; then
    log "running Playwright connectivity + tenant-resolution suites against the tunnel URLs"
    ( cd onboarding && CHATWOOT_URL="$CHAT_URL" DIFY_URL="$DIFY_URL" DIFY_API_URL="$DIFY_API_URL" \
        GRAFANA_URL="$GRAFANA_URL" MIDDLEWARE_URL="$MIDDLEWARE_URL" \
        HANDOFF_SHARED_SECRET="${HANDOFF_SHARED_SECRET:-$(grep -E '^HANDOFF_SHARED_SECRET=' "$ENV_FILE" | cut -d= -f2-)}" \
        npx playwright test tests/01-infra.spec.ts tests/07-hybrid-tenants.spec.ts )
  fi
  log "validation passed"
}

backup()       { BACKUP_DIR="$DUMPS_DIR" bash "$REPO_ROOT/scripts/backup-host.sh"; }
install_cron() {
  local line="0 3 * * * BACKUP_DIR=${DUMPS_DIR} ${BACKUP_RCLONE_REMOTE:+BACKUP_RCLONE_REMOTE=${BACKUP_RCLONE_REMOTE} }${REPO_ROOT}/scripts/backup-host.sh >> ${HOME}/nexaduo-backup.log 2>&1"
  ( crontab -l 2>/dev/null | grep -v 'backup-host.sh' ; echo "$line" ) | crontab -
  log "installed daily 03:00 backup cron:"; echo "  $line"
}
down()   { warn "stopping stack — Postgres volume is preserved (no -v)"; dc down; }
status() { dc ps; }

case "${1:-}" in
  preflight)    preflight ;;
  up)           up ;;
  restore)      restore ;;
  bootstrap)    bootstrap ;;
  validate)     validate ;;
  backup)       backup ;;
  install-cron) install_cron ;;
  down)         down ;;
  status)       status ;;
  *) cat >&2 <<EOF
Usage: $0 {preflight|up|restore|bootstrap|validate|backup|install-cron|down|status}

  bootstrap    clean rebuild: preflight + up + restore DBs from \$DUMPS_DIR
  up           bring up the stack (populated volume; no restore)
  validate     smoke real tunnel URLs + Playwright against them
  backup       run scripts/backup-host.sh once
  install-cron install the daily 03:00 backup cron
  down         stop the stack (Postgres volume PRESERVED)

Env: ENV_FILE=$ENV_FILE  DUMPS_DIR=$DUMPS_DIR  NETWORK=$NETWORK
EOF
     exit 1 ;;
esac
