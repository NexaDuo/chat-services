#!/usr/bin/env bash
# =============================================================================
# wire-self-healing-dify-key.sh
#
# Connects the self-healing agent to its Dify workflow. Run this AFTER importing
# the "Self-Healing Agent Analysis" DSL (dify-apps/Self-Healing Agent Analysis.yml
# or docs/samples/self-healing-agent-analysis.dify.yml) into Dify via the UI.
#
# It is idempotent and reproducible (no manual SQL):
#   1. Finds the imported workflow app in the Dify DB.
#   2. Reuses its API token, or mints one (app-<random>) in api_tokens.
#   3. Upserts DIFY_SELF_HEALING_API_KEY into middleware.configs.
#   4. Restarts the self-healing agent so it picks up the key.
#
# Usage: scripts/wire-self-healing-dify-key.sh ["App Name"]
# =============================================================================
set -euo pipefail

APP_NAME="${1:-Self-Healing Agent Analysis}"
PG="$(docker ps --filter name=postgres --format '{{.Names}}' | head -1)"
[ -n "$PG" ] || { echo "[err] postgres container not running"; exit 1; }

psql() { docker exec -i "$PG" psql -U postgres -v ON_ERROR_STOP=1 -tAq "$@"; }

echo "==> Looking up Dify workflow app: $APP_NAME"
APP_ID="$(psql -d dify -c "select id from apps where name = '$APP_NAME' and mode = 'workflow' order by created_at desc limit 1;")"
if [ -z "$APP_ID" ]; then
  echo "[err] No workflow app named '$APP_NAME' found in Dify."
  echo "      Import dify-apps/'Self-Healing Agent Analysis.yml' in the Dify UI first,"
  echo "      then re-run this script."
  exit 2
fi
TENANT_ID="$(psql -d dify -c "select tenant_id from apps where id = '$APP_ID';")"
echo "    app_id=$APP_ID tenant_id=$TENANT_ID"

echo "==> Resolving API token"
TOKEN="$(psql -d dify -c "select token from api_tokens where app_id = '$APP_ID' and type = 'app' order by created_at limit 1;")"
if [ -z "$TOKEN" ]; then
  TOKEN="app-$(openssl rand -hex 12)"
  psql -d dify -c "insert into api_tokens (id, app_id, tenant_id, type, token, created_at)
                   values (gen_random_uuid(), '$APP_ID', '$TENANT_ID', 'app', '$TOKEN', CURRENT_TIMESTAMP);" >/dev/null
  echo "    minted new token"
else
  echo "    reusing existing token"
fi

echo "==> Upserting DIFY_SELF_HEALING_API_KEY into middleware.configs"
psql -d middleware -c "insert into configs (key, value, updated_at)
                       values ('DIFY_SELF_HEALING_API_KEY', '$TOKEN', NOW())
                       on conflict (key) do update set value = excluded.value, updated_at = NOW();" >/dev/null

echo "==> Restarting self-healing agent"
AGENT="$(docker ps --filter name=self-healing --format '{{.Names}}' | head -1)"
[ -n "$AGENT" ] && docker restart "$AGENT" >/dev/null && echo "    restarted $AGENT" || echo "[warn] agent container not found"

echo "==> Done. Tail the agent for 'Remote config fetched successfully':"
echo "    docker logs -f ${AGENT:-nexaduo-self-healing-agent-1}"
