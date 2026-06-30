#!/usr/bin/env bash
# =============================================================================
# ig-send-test.sh — Self-serve Instagram outbound test.
#
# Sends a test DM using the CURRENT channel_instagram token and prints the raw
# Meta response, so you can iterate on Meta-side settings (app mode, testers,
# handover) without waiting on anyone. Run it after each change in the Meta panel.
#
# The "not owner of the thread" (code 100 / subcode 2534037) error is a Meta-side
# thread-ownership / app-access state, NOT a bug in this stack — the whole
# pipeline (Instagram -> Chatwoot -> Dify -> reply) is validated working; only
# Meta's final delivery permission is gated.
#
# Usage: scripts/ig-send-test.sh [recipient_igsid] ["text"]
#   recipient defaults to the latest inbound sender; text has a default.
# =============================================================================
set -euo pipefail

PG="$(docker ps --filter name=postgres --format '{{.Names}}' | head -1)"
[ -n "$PG" ] || { echo "[err] postgres not running"; exit 1; }

TOK="$(docker exec -i "$PG" psql -U postgres -d chatwoot -tAc \
  "select access_token from channel_instagram order by updated_at desc limit 1;" | tr -d '[:space:]')"
[ -n "$TOK" ] || { echo "[err] no Instagram channel token found"; exit 1; }

RECIP="${1:-$(docker exec -i "$PG" psql -U postgres -d chatwoot -tAc \
  "select source_id from contact_inboxes where inbox_id in (select id from inboxes where channel_type='Channel::Instagram') order by id desc limit 1;" | tr -d '[:space:]')}"
TEXT="${2:-teste de envio Instagram $(date -u +%H:%M:%S)}"

echo "==> recipient=$RECIP"
python3 - "$TOK" "$RECIP" "$TEXT" <<'PY'
import sys, json, urllib.request, urllib.error
tok, recip, text = sys.argv[1], sys.argv[2], sys.argv[3]
url = f"https://graph.instagram.com/v22.0/me/messages?access_token={tok}"
data = json.dumps({"recipient": {"id": recip}, "message": {"text": text}}).encode()
req = urllib.request.Request(url, data=data, headers={"Content-Type": "application/json"})
try:
    r = urllib.request.urlopen(req, timeout=20)
    print("SENT OK", r.status, r.read().decode())
except urllib.error.HTTPError as e:
    body = e.read().decode()
    print("FAILED HTTP", e.code, body)
    if '2534037' in body:
        print("\n-> code 100 / subcode 2534037 = app is not the thread owner.")
        print("   Most likely: app in Development mode (can only message app testers),")
        print("   or the thread is owned by the native Instagram inbox.")
PY