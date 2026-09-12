#!/usr/bin/env bash
# =============================================================================
# backfill-contact-dify-conversations.sh — populate the new
# `contact_dify_conversations` table (issue #204) from the
# `dify_conversation_id` already written into each Chatwoot conversation's
# `custom_attributes`.
#
# WHY (issue #204): agent memory moves from per-Chatwoot-conversation to
# per-CONTACT. Existing data has NO row in the new table yet — only the old,
# per-conversation `custom_attributes.dify_conversation_id`. Without this
# backfill, every contact who already has history restarts fresh the first
# time they message after this change ships until the webhook handler's
# custom_attributes-hint fallback fires and writes the value through to the
# table (`middleware/src/handlers/chatwoot-webhook.ts`, the `resolvedFrom ===
# "legacy"` branch) — this script just makes that immediate instead of lazy,
# and covers contacts who might not message again soon.
#
# NOTE (PR #210 `@rev` review): before that write-through branch existed, this
# claim was FALSE — the hint resolved a value for that one turn but never
# persisted it, so this script was the ONLY thing populating the table for
# any pre-existing contact. That gap is fixed in the handler now; this script
# remains useful only to make the population immediate rather than waiting
# for each contact's next message (or for restoring `middleware` after a
# separate-database DR restore per `AGENTS.md`'s disaster-recovery section).
#
# For each (account_id, contact_id), the MOST RECENT Chatwoot conversation
# (by `updated_at`) that carries a `dify_conversation_id` wins — mirroring
# the "freshest wins" precedent already used by the in-process cache in
# middleware/src/handlers/chatwoot-webhook.ts.
#
# ARMADILHA (same guard as the handler): a conversation with `contact_id IS
# NULL` is EXCLUDED — that is Chatwoot's real-world equivalent of the
# handler's "unknown" sentinel (no linked contact), and must never produce a
# row in `contact_dify_conversations`, which would be meaningless (there is
# no contact to key it by) and — if `contact_id` were ever coerced to a
# literal "unknown" string here — would collide with, and corrupt, the
# handler's own per-conversation fallback for that sentinel.
#
# SAFETY:
#   - DRY-RUN by default: prints the candidate rows and count, writes
#     NOTHING. Pass --apply (or BACKFILL_APPLY=1) to actually write.
#   - Idempotent, and — since PR #210's `@rev` review — non-regressing: the
#     write is `ON CONFLICT (account_id, contact_id) DO NOTHING`, so a row
#     already present in `contact_dify_conversations` is left untouched. A
#     naive `DO UPDATE` (the pre-#210 version of this script) would
#     unconditionally overwrite with whatever `chatwoot.conversations`
#     currently says is freshest, with no comparison against the target
#     row's own `updated_at` — if live traffic already advanced that
#     contact's row (via the handler's own persist path) since the last
#     backfill run, a second run could silently revert it to a stale value
#     still sitting in `custom_attributes`. `DO NOTHING` makes re-running
#     this script strictly additive: it only fills gaps (contacts with no
#     row yet), never regresses a contact the live handler has already
#     progressed.
#   - Reproducibility (AGENTS.md): no manual host intervention — this script
#     IS the fix, versioned here, runnable against any environment's live
#     Postgres via `docker exec`, same pattern as
#     scripts/purge-dangling-blobs.sh.
#   - Does NOT touch Postgres data destructively: only INSERT/UPDATE into the
#     new table; `chatwoot`'s `conversations` table is read-only in this
#     script.
#
# Usage:
#   scripts/backfill-contact-dify-conversations.sh            # dry-run
#   scripts/backfill-contact-dify-conversations.sh --apply     # write rows
# =============================================================================
set -euo pipefail

APPLY="${BACKFILL_APPLY:-0}"
[[ "${1:-}" == "--apply" ]] && APPLY=1

# Locate the Postgres container the same way scripts/backup-host.sh does.
PG="$(docker ps --filter 'name=postgres' --filter 'ancestor=pgvector/pgvector:pg16' --format '{{.Names}}' | head -n1)"
if [[ -z "$PG" ]]; then
  PG="$(docker ps --filter 'name=^/chat-services-postgres' --format '{{.Names}}' | head -n1)"
fi
if [[ -z "$PG" ]]; then
  echo "ERRO: container Postgres não encontrado (docker ps name=postgres)." >&2
  exit 1
fi

echo "[backfill-contact-dify-conversations] container=$PG apply=$APPLY"

# 1. Read candidates from `chatwoot` (read-only). One row per (account_id,
#    contact_id): the most-recently-updated conversation that actually
#    carries a non-empty `dify_conversation_id`. `contact_id IS NOT NULL`
#    excludes the "unknown"-equivalent case (see ARMADILHA above). Fed
#    through stdin, not `-c` (the CHATWOOT_WEBHOOK_TOKEN-rotation lesson:
#    `psql -c` does not interpolate `-v` variables — irrelevant to THIS
#    read-only query since it has none, but kept as the consistent pattern
#    for the write side below).
ROWS="$(docker exec -i "$PG" psql -U postgres -d chatwoot -tA -F $'\t' <<'SQL'
SELECT DISTINCT ON (account_id, contact_id)
  account_id,
  contact_id,
  custom_attributes ->> 'dify_conversation_id' AS dify_conversation_id
FROM conversations
WHERE contact_id IS NOT NULL
  AND custom_attributes ? 'dify_conversation_id'
  AND btrim(custom_attributes ->> 'dify_conversation_id') <> ''
ORDER BY account_id, contact_id, updated_at DESC;
SQL
)"

if [[ -z "$ROWS" ]]; then
  echo "[backfill-contact-dify-conversations] nada para migrar — nenhuma conversation em 'chatwoot' carrega dify_conversation_id."
  exit 0
fi

COUNT="$(printf '%s\n' "$ROWS" | grep -c .)"
echo "[backfill-contact-dify-conversations] ${COUNT} linha(s) candidata(s) (account_id, contact_id, dify_conversation_id da conversation mais recente):"
printf '%s\n' "$ROWS" | sed 's/^/  /'

if [[ "$APPLY" != "1" ]]; then
  echo "[backfill-contact-dify-conversations] DRY-RUN — nada aplicado. Rode com --apply para gravar em contact_dify_conversations (banco 'middleware')."
  exit 0
fi

# 2. Apply idempotently to `middleware`, one INSERT-or-skip per row, values
#    passed as psql variables over stdin (never `-c` with `-v`, and never
#    shell-interpolated into the SQL text) so a Dify-controlled
#    conversation_id string can never be interpreted as SQL. `DO NOTHING`
#    means a row already present (e.g. advanced by live traffic since a
#    prior run) is never overwritten — see the SAFETY note above.
APPLIED=0
while IFS=$'\t' read -r ACCOUNT_ID CONTACT_ID DIFY_CONV_ID; do
  [[ -z "$ACCOUNT_ID" ]] && continue
  docker exec -i "$PG" psql -U postgres -d middleware -v ON_ERROR_STOP=1 \
    -v account_id="$ACCOUNT_ID" -v contact_id="$CONTACT_ID" -v dify_conv="$DIFY_CONV_ID" \
    -q <<'SQL' >/dev/null
INSERT INTO contact_dify_conversations (account_id, contact_id, dify_conversation_id, updated_at)
VALUES (:'account_id', :'contact_id', :'dify_conv', CURRENT_TIMESTAMP)
ON CONFLICT (account_id, contact_id) DO NOTHING;
SQL
  APPLIED=$((APPLIED + 1))
done <<< "$ROWS"

echo "[backfill-contact-dify-conversations] processada(s) ${APPLIED} linha(s) candidata(s) contra contact_dify_conversations (banco 'middleware') — linhas já existentes foram preservadas (DO NOTHING)."
