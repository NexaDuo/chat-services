#!/usr/bin/env bash
# Global Agent Bot cutover (#250). Dry-run by default; never print credentials.
set +x
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPLY=0
case "${1:-}" in
  '') ;;
  --apply) APPLY=1 ;;
  *) echo 'Usage: scripts/provision-chatwoot-bot.sh [--apply]' >&2; exit 1 ;;
esac
[[ $# -le 1 ]] || { echo 'Too many arguments' >&2; exit 1; }
source "$ROOT/scripts/lib/host-health.sh"
require_desktop_engine
RAILS="${CHATWOOT_RAILS_CONTAINER:-chat-services-chatwoot-rails-1}"
# Root .env is the production source, never deploy/.env. Read only the two keys
# needed (never `source` it: values are not shell-quoted), and carry secrets via
# stdin rather than arguments or temporary files.
ENV_FILE="${ENV_FILE:-$ROOT/.env}"
env_value() {
  [[ -f "$ENV_FILE" ]] || return 0
  grep -E "^$1=" "$ENV_FILE" | head -n1 | cut -d= -f2- | sed -e 's/^"//' -e 's/"$//' -e "s/^'//" -e "s/'$//" || true
}
CHATWOOT_WEBHOOK_TOKEN="${CHATWOOT_WEBHOOK_TOKEN:-$(env_value CHATWOOT_WEBHOOK_TOKEN)}"
CHATWOOT_BOT_TOKEN="${CHATWOOT_BOT_TOKEN:-$(env_value CHATWOOT_BOT_TOKEN)}"
export CHATWOOT_WEBHOOK_TOKEN CHATWOOT_BOT_TOKEN
export BOT_PROVISION_APPLY="$APPLY"
python3 - "$ROOT/provisioning/chatwoot-agent-bot.json" <<'PY' | docker exec -i "$RAILS" bundle exec rails runner "$(cat "$ROOT/scripts/lib/provision-chatwoot-bot.rb")"
import json, os, sys
with open(sys.argv[1]) as f:
    config = json.load(f)
config['apply'] = os.environ['BOT_PROVISION_APPLY'] == '1'
config['webhook_token'] = os.environ.get('CHATWOOT_WEBHOOK_TOKEN', '')
config['bot_token'] = os.environ.get('CHATWOOT_BOT_TOKEN', '')
json.dump(config, sys.stdout)
PY
