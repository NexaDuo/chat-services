# Dify kill switch (manual, no-redeploy) — issue #184

Emergency procedure for cutting Dify token consumption **right now**, without
restarting or redeploying `middleware`. Written to be followed under pressure
without reading any code.

## What it does

When `DIFY_KILL_SWITCH` is set to `true`, the middleware stops calling Dify
for every account. Incoming messages keep arriving and stay recorded in
Chatwoot exactly as before — a human can still see and answer them there —
but the bot goes completely silent: no Dify call, no automatic reply, no
error shown to the sender. This is deliberate (same "total silence" decision
already made in issue #182): the sender sees nothing different, they just
stop getting an automated answer.

The flag is **not** an env var and does **not** require touching
`.env`, restarting `middleware`, or redeploying anything. It is a single row
in the `configs` table of the `middleware` Postgres database, read fresh on
every flush (see "Propagation delay" below).

## Turn it ON (stop the bot from answering)

```bash
docker exec -it chat-services-postgres-1 psql -U postgres -d middleware -c \
  "INSERT INTO configs (key, value, updated_at) VALUES ('DIFY_KILL_SWITCH', 'true', NOW())
   ON CONFLICT (key) DO UPDATE SET value = 'true', updated_at = NOW();"
```

Or via the Middleware Config API (needs `HANDOFF_SHARED_SECRET`):

```bash
curl -s -X POST https://middleware.nexaduo.com/config \
  -H "Authorization: Bearer $HANDOFF_SHARED_SECRET" \
  -H "Content-Type: application/json" \
  -d '{"key": "DIFY_KILL_SWITCH", "value": "true"}'
```

## Turn it OFF again (resume normal answering)

Same command, value `false` (or delete the row — an absent row also means
"off", by design):

```bash
docker exec -it chat-services-postgres-1 psql -U postgres -d middleware -c \
  "UPDATE configs SET value = 'false', updated_at = NOW() WHERE key = 'DIFY_KILL_SWITCH';"
```

**Do not leave it ON longer than the incident requires.** A switch that only
turns off the bot and is forgotten is worse than not having it — it becomes
its own silent incident. Treat "turn it back off" as part of the same
procedure, not a follow-up task.

## Confirm it took effect

1. **Read the row back** (fastest, no side effects):
   ```bash
   docker exec -it chat-services-postgres-1 psql -U postgres -d middleware -c \
     "SELECT value, updated_at FROM configs WHERE key = 'DIFY_KILL_SWITCH';"
   ```
2. **Watch the middleware log** for the transition on the next incoming
   message — it logs a `warn` line on every group it skips because of the
   switch:
   ```bash
   docker logs -f chat-services-middleware-1 2>&1 | grep -i "DIFY_KILL_SWITCH"
   ```
   Expect a line like:
   `webhook: DIFY_KILL_SWITCH is ON — skipping Dify call for this group; message stays in Chatwoot for human handoff (issue #184)`
3. **Check the metric** (Prometheus/Grafana, or raw): the counter
   `middleware_dify_kill_switch_skips_total` increments per account for
   every group skipped. `curl -s https://middleware.nexaduo.com/metrics | grep dify_kill_switch`
   is the fastest raw check.
4. **Empirically**: send a real WhatsApp/Instagram message to the affected
   inbox. With the switch ON, no automated reply arrives and Chatwoot shows
   only the inbound message. Turn it OFF and send another message — a normal
   automated reply must arrive again.

## Propagation delay (measured, not assumed)

The middleware has **no in-process cache** for this key (nor for any other
config value read in the hot path — `resolveTenant()` reads `tenants` the
same way). Every flush issues one `SELECT value FROM configs WHERE key = $1`
against the local Postgres container. Locally this round-trip measured
**well under 10ms**. The only real-world delay is the burst debounce window
itself (`WEBHOOK_DEBOUNCE_MS`, default 2500ms): a message that was already
buffered on a debounce timer will not be pulled back once flushed, but the
flag is read again fresh at every flush, so the very next debounce cycle
(at most ~`WEBHOOK_DEBOUNCE_MS` after the switch is flipped) sees the new
value. In practice: **effect within a few seconds**, never longer than one
debounce window plus one query round-trip.

## Where the check lives, and why there

The check is in `flushGroup()` in
`middleware/src/handlers/chatwoot-webhook.ts`, immediately before the Dify
call — not in the webhook route handler that enqueues messages into the
per-conversation debouncer (PR #180). If the check lived at enqueue time
instead, a burst that was already buffered before the operator flipped the
switch would still reach Dify when its debounce timer fired, which is
exactly the scenario this switch exists to prevent. Checking at flush time
means the last read of the flag is always the one that decides whether Dify
gets called.

## Fail-safe behavior (by design)

Any of the following situations resolve to **"off" (bot keeps answering)**,
never to "on":

- No `DIFY_KILL_SWITCH` row in `configs` (fresh bootstrap default).
- `value` is `NULL` or an empty string.
- `value` is anything other than the exact string `true` (case-insensitive,
  surrounding whitespace tolerated — `"  TRUE "` counts as ON, `"yes"` does
  not).
- A Postgres error while reading the row (connection drop, pool exhaustion,
  etc.) — logged as a `warn`, never thrown into the flush.

This is the deliberate mirror of the issue #152 lesson (self-healing silently
degrading when its config read failed): here, the accident to avoid is
silencing the bot by accident, so every ambiguous read defaults to normal
operation instead.

See also: `AGENTS.md` → "Configuration model (hybrid)".
