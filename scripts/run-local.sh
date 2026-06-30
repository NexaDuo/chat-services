#!/usr/bin/env bash
# =============================================================================
# run-local.sh — Run the entire chat-services stack on THIS machine.
#
# Why this exists: to leave paid cloud hosting and run the production stack
# locally, fronted by the SAME Cloudflare Tunnel (so chat.nexaduo.com etc. keep
# working). Data comes from the daily GCS pg_dump backups. This mirrors how CI
# runs the stack via compose (stack-compose-playwright.yml) but with the REAL
# production secrets (pulled from Secret Manager) and the real domains, plus a
# stand-in Traefik (`coolify-proxy`) and the cloudflared tunnel.
#
# Usage:
#   scripts/run-local.sh env       # (re)generate .env from Secret Manager
#   scripts/run-local.sh build     # build middleware + self-healing images
#   scripts/run-local.sh db        # start postgres+redis only, wait healthy
#   scripts/run-local.sh restore [DUMP_DIR]   # restore the 7 DBs from dumps
#   scripts/run-local.sh up        # start the full stack (app + proxy + tunnel)
#   scripts/run-local.sh tunnel    # (re)start cloudflared only
#   scripts/run-local.sh status    # docker compose ps
#   scripts/run-local.sh down      # stop everything (keeps volumes/data)
#   scripts/run-local.sh all [DUMP_DIR]   # env→build→db→restore→up, end to end
#
# Safe to re-run. `down` never deletes volumes. The tunnel only takes over
# while the GCP VM is stopped (otherwise two connectors fight).
# =============================================================================
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$(pwd)"

PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
BASE_DOMAIN="${BASE_DOMAIN:-nexaduo.com}"
DUMP_DIR_DEFAULT="${HOME}/nexaduo-local/dumps"

export COMPOSE_FILE="deploy/docker-compose.shared.yml:deploy/docker-compose.chatwoot.yml:deploy/docker-compose.dify.yml:deploy/docker-compose.nexaduo.yml:docker-compose.yml:deploy/docker-compose.localproxy.yml"
export COMPOSE_PROJECT_NAME="nexaduo"

# The 7 logical databases backed up daily to GCS.
DBS=(chatwoot dify dify_plugin evolution middleware self_healing grafana)

log()  { printf '\033[1;36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[warn]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[err]\033[0m %s\n' "$*" >&2; exit 1; }

sec() { gcloud secrets versions access latest --secret="$1" --project="$PROJECT_ID" 2>/dev/null; }

pg_container() { docker ps --filter "name=postgres" --format '{{.Names}}' | grep -E 'postgres' | head -1; }

cmd_env() {
  log "Generating .env from Secret Manager (project ${PROJECT_ID})..."
  # Pull every production secret. Encryption-critical keys (CHATWOOT_SECRET_KEY_BASE,
  # DIFY_SECRET_KEY) MUST be the production values or the restored channel/provider
  # configs won't decrypt.
  local POSTGRES_PASSWORD REDIS_PASSWORD CHATWOOT_SECRET_KEY_BASE CHATWOOT_API_TOKEN
  local CHATWOOT_PLATFORM_TOKEN DIFY_SECRET_KEY DIFY_SANDBOX_API_KEY DIFY_PLUGIN_DAEMON_KEY
  local DIFY_PLUGIN_DIFY_INNER_API_KEY EVOLUTION_API_KEY HANDOFF_SHARED_SECRET ADMIN_PASSWORD
  local ADMIN_EMAIL GRAFANA_PASSWORD GOOGLE_ID GOOGLE_SECRET TUNNEL_TOKEN
  # Self-healing "action": reuse the local gh CLI token so the agent can open
  # issues without a separately-managed PAT. Empty if gh isn't logged in.
  local SELF_HEALING_GITHUB_TOKEN
  SELF_HEALING_GITHUB_TOKEN="$(gh auth token 2>/dev/null || true)"

  POSTGRES_PASSWORD="$(sec postgres_password)"
  REDIS_PASSWORD="$(sec redis_password)"
  CHATWOOT_SECRET_KEY_BASE="$(sec chatwoot_secret_key_base)"
  CHATWOOT_API_TOKEN="$(sec chatwoot_api_token)"
  CHATWOOT_PLATFORM_TOKEN="$(sec chatwoot_platform_token)"
  DIFY_SECRET_KEY="$(sec dify_secret_key)"
  DIFY_SANDBOX_API_KEY="$(sec dify_sandbox_api_key)"
  DIFY_PLUGIN_DAEMON_KEY="$(sec dify_plugin_daemon_key)"
  DIFY_PLUGIN_DIFY_INNER_API_KEY="$(sec dify_plugin_dify_inner_api_key)"
  EVOLUTION_API_KEY="$(sec evolution_authentication_api_key)"
  HANDOFF_SHARED_SECRET="$(sec handoff_shared_secret)"
  ADMIN_PASSWORD="$(sec admin_password)"
  ADMIN_EMAIL="$(sec admin_email)"
  GRAFANA_PASSWORD="$(sec grafana_admin_password)"
  GOOGLE_ID="$(sec google_oauth_client_id)"
  GOOGLE_SECRET="$(sec google_oauth_client_secret)"
  TUNNEL_TOKEN="$(sec tunnel_token)"

  [ -n "$CHATWOOT_SECRET_KEY_BASE" ] || die "chatwoot_secret_key_base empty — cannot decrypt restored data"
  [ -n "$DIFY_SECRET_KEY" ]          || die "dify_secret_key empty — cannot decrypt restored data"
  [ -n "$TUNNEL_TOKEN" ]             || die "tunnel_token empty — tunnel won't register"

  # CHATWOOT_WEBHOOK_TOKEN is not in Secret Manager (was generated per-deploy on
  # the VM). Reuse an existing one if a previous .env had it, else mint a stable
  # one. Inbound Chatwoot->middleware webhooks may need this reconciled with the
  # webhook config in the restored Chatwoot DB.
  local CHATWOOT_WEBHOOK_TOKEN=""
  if [ -f .env ]; then CHATWOOT_WEBHOOK_TOKEN="$(grep -E '^CHATWOOT_WEBHOOK_TOKEN=' .env | head -1 | cut -d= -f2- || true)"; fi
  [ -n "$CHATWOOT_WEBHOOK_TOKEN" ] || CHATWOOT_WEBHOOK_TOKEN="$(openssl rand -hex 32)"

  cat > .env <<EOF
# Generated by scripts/run-local.sh from GCP Secret Manager. Do NOT commit.
COMPOSE_PROJECT_NAME=nexaduo
TZ=America/Sao_Paulo
NEXADUO_CONF_PATH=${ROOT}

# --- Postgres / Redis (shared) ---
POSTGRES_USER=postgres
POSTGRES_PASSWORD=${POSTGRES_PASSWORD}
POSTGRES_HOST=postgres
POSTGRES_PORT=5432
REDIS_PASSWORD=${REDIS_PASSWORD}
REDIS_HOST=redis
REDIS_PORT=6379

# --- Admin / handoff ---
ADMIN_EMAIL=${ADMIN_EMAIL}
ADMIN_PASSWORD=${ADMIN_PASSWORD}
HANDOFF_SHARED_SECRET=${HANDOFF_SHARED_SECRET}
HANDOFF_LABEL=atendimento-humano

# --- Domains (served via Cloudflare Tunnel -> coolify-proxy) ---
CHATWOOT_DOMAIN=chat.${BASE_DOMAIN}
DIFY_DOMAIN=dify.${BASE_DOMAIN}
GRAFANA_DOMAIN=grafana.${BASE_DOMAIN}
EVOLUTION_DOMAIN=evolution.${BASE_DOMAIN}
MIDDLEWARE_DOMAIN=middleware.${BASE_DOMAIN}

# --- Chatwoot ---
CHATWOOT_SECRET_KEY_BASE=${CHATWOOT_SECRET_KEY_BASE}
CHATWOOT_FRONTEND_URL=https://chat.${BASE_DOMAIN}
CHATWOOT_FORCE_SSL=false
FORCE_SSL=false
CHATWOOT_API_TOKEN=${CHATWOOT_API_TOKEN}
CHATWOOT_PLATFORM_TOKEN=${CHATWOOT_PLATFORM_TOKEN}
CHATWOOT_WEBHOOK_TOKEN=${CHATWOOT_WEBHOOK_TOKEN}
CHATWOOT_BASE_URL=http://chatwoot-rails:3000

# --- Google OAuth (Chatwoot + Grafana) ---
GOOGLE_OAUTH_CLIENT_ID=${GOOGLE_ID}
GOOGLE_OAUTH_CLIENT_SECRET=${GOOGLE_SECRET}
GOOGLE_OAUTH_CALLBACK_URL=https://chat.${BASE_DOMAIN}/omniauth/google_oauth2/callback
GOOGLE_CLIENT_ID=${GOOGLE_ID}
GOOGLE_CLIENT_SECRET=${GOOGLE_SECRET}
GOOGLE_ID=${GOOGLE_ID}
GOOGLE_SECRET=${GOOGLE_SECRET}

# --- Evolution API ---
EVOLUTION_API_KEY=${EVOLUTION_API_KEY}
EVOLUTION_AUTHENTICATION_API_KEY=${EVOLUTION_API_KEY}

# --- Dify ---
DIFY_SECRET_KEY=${DIFY_SECRET_KEY}
DIFY_BASE_URL=http://dify-api:5001/v1
DIFY_CONSOLE_API_URL=https://dify.${BASE_DOMAIN}
DIFY_CONSOLE_WEB_URL=https://dify.${BASE_DOMAIN}
DIFY_SERVICE_API_URL=https://dify.${BASE_DOMAIN}
DIFY_APP_API_URL=https://dify.${BASE_DOMAIN}
DIFY_APP_WEB_URL=https://dify.${BASE_DOMAIN}
DIFY_SANDBOX_API_KEY=${DIFY_SANDBOX_API_KEY}
DIFY_PLUGIN_DAEMON_KEY=${DIFY_PLUGIN_DAEMON_KEY}
DIFY_PLUGIN_DIFY_INNER_API_KEY=${DIFY_PLUGIN_DIFY_INNER_API_KEY}
DIFY_VECTOR_STORE=pgvector
DIFY_CORS_ALLOW_ORIGINS=*
DIFY_LOG_LEVEL=INFO
DIFY_API_ENABLE_METRICS=true
INNER_API_METRICS_ENABLED=true

# --- Cookies / sessions (HTTPS + subdomains) ---
COOKIE_DOMAIN=.${BASE_DOMAIN}
NEXT_PUBLIC_COOKIE_DOMAIN=.${BASE_DOMAIN}
SESSION_COOKIE_SECURE=true

# --- Middleware / self-healing ---
MIDDLEWARE_PORT=4000
MIDDLEWARE_LOG_LEVEL=info
TENANT_MAP={}
DIFY_REQUEST_TIMEOUT_MS=30000
MIDDLEWARE_IMAGE=nexaduo/middleware:local
SELF_HEALING_IMAGE=nexaduo/self-healing-agent:local
# Self-healing agent "action" (open GitHub issues for severe insights). Optional.
SELF_HEALING_GITHUB_TOKEN=${SELF_HEALING_GITHUB_TOKEN}
SELF_HEALING_GITHUB_REPO=NexaDuo/chat-services

# --- Observability ---
GRAFANA_ADMIN_USER=admin
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
GRAFANA_PASSWORD=${GRAFANA_PASSWORD}
GF_SERVER_ROOT_URL=https://grafana.${BASE_DOMAIN}

# --- Cloudflare Tunnel ---
TUNNEL_TOKEN=${TUNNEL_TOKEN}
EOF
  chmod 600 .env
  log ".env written ($(grep -c '=' .env) keys)."
}

cmd_build() {
  log "Building middleware image..."
  docker build -t nexaduo/middleware:local ./middleware
  local sh_dir="./agents/self-healing"
  [ -d "$sh_dir" ] || sh_dir="./self-healing"
  log "Building self-healing image ($sh_dir)..."
  docker build -t nexaduo/self-healing-agent:local "$sh_dir"
}

cmd_db() {
  docker network create nexaduo-network 2>/dev/null || true
  log "Starting postgres + redis..."
  docker compose up -d postgres redis
  log "Waiting for postgres health..."
  for i in $(seq 1 30); do
    local pg; pg="$(pg_container || true)"
    if [ -n "$pg" ] && docker exec "$pg" pg_isready -U postgres >/dev/null 2>&1; then
      log "Postgres ready ($pg)."
      # If the data volume was initialized by a previous run, POSTGRES_PASSWORD
      # from .env was ignored (Postgres only honors it on first init). Force the
      # superuser password to match .env so app containers can auth over TCP.
      local pw; pw="$(grep -E '^POSTGRES_PASSWORD=' .env | head -1 | cut -d= -f2-)"
      [ -n "$pw" ] && docker exec "$pg" psql -U postgres -q -c "ALTER USER postgres WITH PASSWORD '$pw';" >/dev/null 2>&1 \
        && log "Superuser password synced to .env."
      return 0
    fi
    sleep 3
  done
  die "Postgres did not become ready."
}

cmd_restore() {
  local dir="${1:-$DUMP_DIR_DEFAULT}"
  [ -d "$dir" ] || die "Dump dir not found: $dir"
  local pg; pg="$(pg_container)"; [ -n "$pg" ] || die "Postgres container not running (run: $0 db)"
  log "Restoring ${#DBS[@]} databases from $dir into $pg..."
  for db in "${DBS[@]}"; do
    local f; f="$(ls -1 "$dir"/${db}-*.sql.gz 2>/dev/null | sort | tail -1 || true)"
    if [ -z "$f" ]; then warn "no dump for '$db' in $dir — skipping"; continue; fi
    # Ensure the DB exists (dumps are single-DB --clean --if-exists, no CREATE DATABASE).
    docker exec "$pg" psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='${db}'" | grep -q 1 \
      || docker exec "$pg" createdb -U postgres "$db"
    log "  restoring $db  <-  $(basename "$f")"
    gunzip -c "$f" | docker exec -i "$pg" psql -U postgres -q -v ON_ERROR_STOP=0 -d "$db" >/dev/null 2>>"/tmp/restore-${db}.err" \
      && log "    $db OK" || warn "    $db finished with warnings (see /tmp/restore-${db}.err)"
  done
}

cmd_up() {
  docker network create nexaduo-network 2>/dev/null || true
  log "Starting full stack (apps + coolify-proxy + cloudflared)..."
  docker compose up -d --remove-orphans
  log "Stack started. Use '$0 status' to watch health."
}

cmd_tunnel() {
  log "Restarting cloudflared..."
  docker compose up -d cloudflared
}

cmd_status() { docker compose ps; }

cmd_down() {
  log "Stopping stack (volumes/data preserved)..."
  docker compose down
}

cmd_all() {
  cmd_env
  cmd_build
  cmd_db
  cmd_restore "${1:-$DUMP_DIR_DEFAULT}"
  cmd_up
}

case "${1:-}" in
  env)     cmd_env ;;
  build)   cmd_build ;;
  db)      cmd_db ;;
  restore) cmd_restore "${2:-}" ;;
  up)      cmd_up ;;
  tunnel)  cmd_tunnel ;;
  status)  cmd_status ;;
  down)    cmd_down ;;
  all)     cmd_all "${2:-}" ;;
  *) echo "usage: $0 {env|build|db|restore [DIR]|up|tunnel|status|down|all [DIR]}"; exit 1 ;;
esac
