# Middleware — Chatwoot ⇄ Dify Adapter

Node.js/TypeScript service (Fastify 5) that closes the messaging loop between Chatwoot (hub) and Dify (agentic brain). This is the single source of truth where multi-tenancy logic by `account_id` is resolved.

## Production URLs

- **Webhook Endpoint:** `https://middleware.nexaduo.com/webhooks/chatwoot`
- **Handoff Endpoint:** `https://middleware.nexaduo.com/tools/handoff`

## Responsibilities

1. **Chatwoot Webhook** (`POST /webhooks/chatwoot`)
   - Filters events: only `message_created` + `message_type: incoming` + sender `contact` + non-private + non-empty content.
   - Receives native Agent Bot events only for enabled inboxes. Replies only to `pending` conversations with no human assignee; `open`, `resolved`, and `snoozed` belong to humans.
   - Requires `conversation.status`, `conversation.meta.assignee`, and `conversation.meta.assignee_type`. Missing/invalid ownership returns HTTP 200 `skipped: missing_ownership_fields` and logs a warning, without a private note.
   - Checks ownership before buffering, then reads current ownership with the user token at flush and before posting. A handoff during debounce or Dify execution suppresses the answer without advancing the watermark. Failed ownership reads also suppress replies; the final REST read/post cannot be atomic.
   - Resolves the tenant from the middleware `tenants` table by `account_id`.
   - Retrieves per-contact Dify memory from `contact_dify_conversations`, with the legacy conversation attribute as a fallback.
   - Calls `POST {dify_base_url}/chat-messages` (blocking mode) with `user = "{account_id}:{contact_id}"` and inputs containing Chatwoot IDs.
   - Posts Dify's response back via `POST /api/v1/accounts/{id}/conversations/{id}/messages`.
   - In case of error/timeout, posts a **private note** only while the conversation still belongs to the bot.

2. **Handoff HTTP Tool** (`POST /tools/handoff`)
   - Exposed to Dify as an HTTP Tool (requires `x-handoff-secret: $HANDOFF_SHARED_SECRET` header).
   - Reopens the conversation (`toggle_status → open`), adds the `atendimento-humano` label, and posts a private note with the agent's summary.

3. **Observability** (`GET /metrics`)
   - Exposes Prometheus metrics: `middleware_dify_tokens_total{account_id,kind}`, `middleware_dify_requests_total{account_id,status}`, `middleware_dify_request_duration_seconds`, `middleware_errors_total`, `middleware_handoffs_total`, `middleware_bot_ownership_skips_total{account_id,reason}`, plus standard Node metrics. The ownership counter counts rejected incoming messages or suppressed buffered groups; reasons are `conversation_open`, `conversation_resolved`, `conversation_snoozed`, `human_assignee`, `missing_ownership_fields`, and `ownership_lookup_failed`.

## Environment Variables (see `.env.production.example` at root)

| Var | Required | Description |
| :-- | :--: | :-- |
| `PORT` | No | Default `4000` |
| `LOG_LEVEL` | No | `trace\|debug\|info\|warn\|error\|fatal` — default `info` |
| `CHATWOOT_BASE_URL` | ✅ | Internal Chatwoot URL (e.g., `http://chatwoot-rails:3000`) |
| `CHATWOOT_API_TOKEN` | ✅ | `api_access_token` of a Chatwoot admin user |
| `CHATWOOT_BOT_TOKEN` | No | Agent Bot access token for contact replies; empty falls back to the user token. Reads, custom attributes, private notes, status changes and labels retain the user token. |
| `CHATWOOT_WEBHOOK_TOKEN` | Yes in production | Shared webhook authentication in the bot outgoing URL query; never log it. Signature verification is a follow-up. |
| `DIFY_BASE_URL` | ✅ | Internal Dify URL (e.g., `http://dify-api:5001/v1`) |
| `DIFY_REQUEST_TIMEOUT_MS` | No | Default `30000` |
| `HANDOFF_SHARED_SECRET` | ✅ | Secret ≥16 chars for `x-handoff-secret` header |
| `HANDOFF_LABEL` | No | Default `atendimento-humano` |

> The `CHATWOOT_API_TOKEN` **only exists after the first Chatwoot setup**. Create the super-admin in the UI (`chat.nexaduo.com`), copy the token from *Profile Settings → Access Token*, add it to `.env`, and recreate only middleware using the compose chain below. The user must have access to every bot-enabled account, including conversation reads.

## Run Locally (without Docker)

```bash
cd middleware
npm install
npm run typecheck         # confirm TS compiles
cp ../.env.example .env   # fill in CHATWOOT_BASE_URL/TOKEN, DIFY_BASE_URL, etc.
npm run dev               # tsx watch — auto-reload
```

## Build + Prod

```bash
npm run build    # output to dist/
npm run start    # node dist/index.js
```

In production, recreate only middleware with `--no-deps` and the full compose chain below.

## Routes

- `POST /webhooks/chatwoot` — Chatwoot webhook handler
- `POST /tools/handoff` — HTTP Tool called by Dify (requires `x-handoff-secret`)
- `GET /health` — JSON `{ status: "ok", uptimeSeconds }`
- `GET /metrics` — Prometheus metrics (text/plain; version=0.0.4)

## Structure

```
src/
├── index.ts                       # Fastify bootstrap + graceful shutdown
├── config.ts                      # env validation (zod) + database tenant resolution
├── logger.ts                      # pino (pretty in dev, JSON in prod)
├── metrics.ts                     # prom-client (registry + counters/histograms)
├── chatwoot.ts                    # Chatwoot REST client (axios)
├── dify.ts                        # Dify Chat API REST client (axios)
└── handlers/
    ├── health.ts                  # /health + /metrics
    ├── chatwoot-webhook.ts        # main messaging loop
    └── handoff.ts                 # human handoff (Dify tool)
```

## Agent Bot cutover (#250)

The global bot (`account_id = NULL`) is shared across accounts; activation is per inbox.
`provisioning/chatwoot-agent-bot.json` is the versioned selection; an inbox not listed
there is human-only. An inbox selector is
`{"account_id": 3, "name": "miau.duda", "channel_type": "Channel::Instagram"}`.
Exact name plus account and channel type survives changed inbox database
IDs on rebuild. Treat names as managed identifiers: a rename requires updating this file.
Missing or ambiguous matches, duplicate selectors and another bot's binding abort the run.

1. Populate and review the inbox list. Confirm the existing tenant mappings. Put the
   webhook token and, optionally, a privately generated bot access token in the root
   `.env`. The script assigns the supplied bot token to the global bot without printing
   it; it does not retrieve or expose a token. Empty preserves the existing bot token
   and middleware's user-token fallback. Keep the bot name stable to identify it on reruns.
2. Build the changed middleware image using the normal image build process, then
   recreate **only middleware** (production project is `chat-services`, CI is `nexaduo`):

   ```bash
   docker compose --env-file .env -p chat-services \
     -f deploy/docker-compose.shared.yml -f deploy/docker-compose.chatwoot.yml \
     -f deploy/docker-compose.dify.yml -f deploy/docker-compose.nexaduo.yml \
     -f docker-compose.yml -f deploy/docker-compose.localproxy.yml \
     -f deploy/docker-compose.isolated.yml up -d --no-deps --force-recreate middleware
   ```

3. Run `scripts/provision-chatwoot-bot.sh` for the read-only plan, then
   `scripts/provision-chatwoot-bot.sh --apply`. It requires Docker Desktop via the shared
   host guard, targets `chat-services-chatwoot-rails-1` (override with
   `CHATWOOT_RAILS_CONTAINER`), and uses Rails runner. It creates/updates the global bot,
   activates selected inboxes, deactivates this bot's omitted inbox bindings, and deletes
   matching account webhooks **in one database transaction**. An empty selection refuses
   `--apply`. It never replaces another bot. Removal matches exact endpoint origin/path,
   ignoring query tokens; declare any other middleware URL aliases in `legacy_endpoints`.
   The new outgoing URL uses the internal Docker service, with query-token authentication.
   The transaction prevents a configuration window with both delivery mechanisms active;
   already queued account-webhook jobs cannot be recalled. Schedule cutover during quiet
   traffic and let existing jobs finish when strict absence of duplicate deliveries is
   required. Existing conversations keep their status; only deliberately returning an
   unassigned conversation to `pending` gives it back to the bot.
4. Run `scripts/run-stack.sh validate` and `scripts/health-check-all.sh`. Confirm a new
   contact message in an enabled inbox starts `pending` and gets a bot-authored reply;
   after handoff (`open` + `atendimento-humano`) subsequent messages get no bot reply.
   Verify an unattached inbox stays human-only. Inspect ownership skip metrics and the
   affected middleware container. No Postgres recreation is needed.

The CI workflow runs `scripts/tests/test-chatwoot-agent-bot.sh` against its ephemeral
Chatwoot and middleware. It creates real messages through Rails model callbacks and
executes the real Agent Bot webhook job inline, forwarding the unchanged HTTP payload to
middleware and asserting the ownership fields and an unattached-inbox negative control.
Inline jobs remove queue timing ambiguity for that negative assertion; production Sidekiq
scheduling/signature verification are not tested here. This is an internal webhook flow,
so unit and producer contract tests cover it rather than a browser-only Playwright test.
