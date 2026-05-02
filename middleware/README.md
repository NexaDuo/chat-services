# Middleware — Chatwoot ⇄ Dify Adapter

Node.js/TypeScript service (Fastify 5) that closes the messaging loop between Chatwoot (hub) and Dify (agentic brain). This is the single source of truth where multi-tenancy logic by `account_id` is resolved.

## Production URLs

- **Webhook Endpoint:** `https://api.nexaduo.com/webhooks/chatwoot`
- **Handoff Endpoint:** `https://api.nexaduo.com/tools/handoff`

## Responsibilities

1. **Chatwoot Webhook** (`POST /webhooks/chatwoot`)
   - Filters events: only `message_created` + `message_type: incoming` + sender `contact` + non-private + non-empty content.
   - Resolves tenant via `TENANT_MAP[account_id] → { dify_api_key, dify_base_url? }`.
   - Retrieves `dify_conversation_id` saved in `conversation.custom_attributes` for memory continuity.
   - Calls `POST {dify_base_url}/chat-messages` (blocking mode) with `user = "{account_id}:{contact_id}"` and inputs containing Chatwoot IDs.
   - Posts Dify's response back via `POST /api/v1/accounts/{id}/conversations/{id}/messages`.
   - In case of error/timeout, posts a **private note** in Chatwoot with context for human operators.

2. **Handoff HTTP Tool** (`POST /tools/handoff`)
   - Exposed to Dify as an HTTP Tool (requires `x-handoff-secret: $HANDOFF_SHARED_SECRET` header).
   - Reopens the conversation (`toggle_status → open`), adds the `atendimento-humano` label, and posts a private note with the agent's summary.

3. **Observability** (`GET /metrics`)
   - Exposes Prometheus metrics: `middleware_dify_tokens_total{account_id,kind}`, `middleware_dify_requests_total{account_id,status}`, `middleware_dify_request_duration_seconds`, `middleware_errors_total`, `middleware_handoffs_total`, plus standard Node metrics.

## Environment Variables (see `.env.example` at root)

| Var | Required | Description |
| :-- | :--: | :-- |
| `PORT` | No | Default `4000` |
| `LOG_LEVEL` | No | `trace\|debug\|info\|warn\|error\|fatal` — default `info` |
| `CHATWOOT_BASE_URL` | ✅ | Internal Chatwoot URL (e.g., `http://chatwoot-rails:3000`) |
| `CHATWOOT_API_TOKEN` | ✅ | `api_access_token` of a Chatwoot admin user |
| `DIFY_BASE_URL` | ✅ | Internal Dify URL (e.g., `http://dify-api:5001/v1`) |
| `DIFY_REQUEST_TIMEOUT_MS` | No | Default `30000` |
| `TENANT_MAP` | ✅ | JSON: `{"<account_id>":{"dify_api_key":"app-..."}}` |
| `HANDOFF_SHARED_SECRET` | ✅ | Secret ≥16 chars for `x-handoff-secret` header |
| `HANDOFF_LABEL` | No | Default `atendimento-humano` |

> The `CHATWOOT_API_TOKEN` **only exists after the first Chatwoot setup**. Create the super-admin in the UI (`chat.nexaduo.com`), copy the token from *Profile Settings → Access Token*, add it to `.env`, and run `docker compose restart middleware`.

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

In production, the container runs via `docker compose up -d middleware` — see `docker-compose.yml` at the root.

## Routes

- `POST /webhooks/chatwoot` — Chatwoot webhook handler
- `POST /tools/handoff` — HTTP Tool called by Dify (requires `x-handoff-secret`)
- `GET /health` — JSON `{ status: "ok", uptimeSeconds }`
- `GET /metrics` — Prometheus metrics (text/plain; version=0.0.4)

## Structure

```
src/
├── index.ts                       # Fastify bootstrap + graceful shutdown
├── config.ts                      # env validation (zod) + TENANT_MAP parser
├── logger.ts                      # pino (pretty in dev, JSON in prod)
├── metrics.ts                     # prom-client (registry + counters/histograms)
├── chatwoot.ts                    # Chatwoot REST client (axios)
├── dify.ts                        # Dify Chat API REST client (axios)
└── handlers/
    ├── health.ts                  # /health + /metrics
    ├── chatwoot-webhook.ts        # main messaging loop
    └── handoff.ts                 # human handoff (Dify tool)
```
