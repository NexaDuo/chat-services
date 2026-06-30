#!/usr/bin/env bash
# =============================================================================
# seed-chatwoot-webhook.sh
#
# Creates the Chatwoot -> middleware account webhook that forwards `message_created`
# events to the adapter (which then calls Dify). This link was historically set up
# by hand in the Chatwoot UI and never lived in code, so a restored/rebuilt
# environment has no webhook and inbound messages never reach Dify.
#
# Idempotent: one account-level webhook per account, keyed by URL. Re-running
# updates the subscriptions/URL in place.
#
# The token rides in the query string (`?token=`) because Chatwoot's native
# webhooks can only customize the URL, not send custom headers — the middleware
# handler accepts the token from either place.
#
# Usage: scripts/seed-chatwoot-webhook.sh [account_id]   # default: all accounts
# =============================================================================
set -euo pipefail

ACCOUNT_ARG="${1:-}"
MW_URL="${MIDDLEWARE_WEBHOOK_URL:-http://middleware:4000/webhooks/chatwoot}"

CW="$(docker ps --filter name=chatwoot-rails --format '{{.Names}}' | head -1)"
[ -n "$CW" ] || { echo "[err] chatwoot-rails container not running"; exit 1; }
MW="$(docker ps --filter name=^/nexaduo-middleware --format '{{.Names}}' | head -1)"
[ -n "$MW" ] || MW="$(docker ps --filter name=middleware --format '{{.Names}}' | head -1)"

# Pull the shared token from the middleware container so both sides agree.
TOKEN="$(docker exec "$MW" printenv CHATWOOT_WEBHOOK_TOKEN 2>/dev/null || true)"
URL="$MW_URL"
[ -n "$TOKEN" ] && URL="${MW_URL}?token=${TOKEN}"

echo "==> Seeding Chatwoot account webhook -> ${MW_URL}$([ -n "$TOKEN" ] && echo '?token=***')"
echo "    accounts: ${ACCOUNT_ARG:-ALL}"

docker exec -i \
  -e SEED_URL="$URL" \
  -e SEED_ACCOUNT="$ACCOUNT_ARG" \
  "$CW" bundle exec rails runner '
    url = ENV["SEED_URL"]
    subs = %w[message_created]
    accounts = ENV["SEED_ACCOUNT"].to_s.empty? ? Account.all : Account.where(id: ENV["SEED_ACCOUNT"].to_i)
    accounts.each do |acc|
      # Match on the path (ignoring the token query) so rotating the token does
      # not create a duplicate row.
      base = url.split("?").first
      wh = acc.webhooks.detect { |w| w.url.to_s.split("?").first == base }
      wh ||= acc.webhooks.new
      wh.url = url
      wh.webhook_type = "account_type"
      wh.subscriptions = subs
      wh.save!
      puts "account=#{acc.id} webhook=##{wh.id} subs=#{wh.subscriptions.inspect}"
    end
  '

echo "==> Done."
