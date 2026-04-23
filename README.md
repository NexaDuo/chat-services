<!-- generated-by: gsd-doc-writer -->
# chat-services — NexaDuo Omnichannel AI Stack

A **production-ready from day one** omnichannel support stack: Chatwoot as the single hub, Evolution API for WhatsApp/Instagram, Dify as the agentic brain (RAG + MCP), and a Node.js middleware that closes the Chatwoot ⇄ Dify loop.

> Full blueprint in pt-BR: [`docs/plans/first-setup.plan.md`](docs/plans/first-setup.plan.md).
> AI contribution conventions: [`CLAUDE.md`](CLAUDE.md).

## Production URLs

The stack is orchestrated through Coolify and exposed on the following domains:

- **Coolify (Dashboard):** [coolify.nexaduo.com](https://coolify.nexaduo.com)
- **Chatwoot (Inbox/CRM):** [chat.nexaduo.com](https://chat.nexaduo.com)
- **Dify (AI/Agents):** [dify.nexaduo.com](https://dify.nexaduo.com)

### Multi-tenancy Strategy (Future)
To support multiple tenants in a shared stack, routing will be path-based:
- **Chatwoot:** `chat.nexaduo.com/{tenant}/`
- **Dify:** `dify.nexaduo.com/{tenant}/`

## Architecture

```
           ┌────────────┐       ┌────────────┐      ┌─────────────────────┐
WhatsApp ─>│ Evolution  │──────>│  Chatwoot  │─────>│   Middleware (TS)   │
           │  API v2    │       │  (hub/CRM) │      │  /webhooks/chatwoot │
           └────────────┘       └────────────┘      └──────────┬──────────┘
                                     ▲                         │
                                     │  agent response         │
                                     │                         ▼
                                     │               ┌─────────────────┐
                                     └───────────────│  Dify (agent +  │
                                                     │  RAG pgvector)  │
                                                     └────────┬────────┘
                                                              │
                                                              ▼
                                                    ┌──────────────────┐
                                                    │  Azure OpenAI    │
                                                    │  gpt-4o(-mini)   │
                                                    └──────────────────┘
```

Shared infrastructure: **one** Postgres 16 + `pgvector` (3 DBs: `chatwoot`, `dify`, `dify_plugin`, `evolution`) and **one** Redis 7 (logical DBs `0` = Dify, `1` = Chatwoot, `2` = Evolution).

## Quickstart

### 1. Secrets

```bash
cp .env.example .env

# Generate strong values (copy them into .env):
openssl rand -hex 64    # CHATWOOT_SECRET_KEY_BASE, DIFY_SECRET_KEY
openssl rand -hex 32    # REDIS_PASSWORD, POSTGRES_PASSWORD,
                        # EVOLUTION_AUTHENTICATION_API_KEY,
                        # DIFY_SANDBOX_API_KEY, DIFY_PLUGIN_DAEMON_KEY,
                        # DIFY_PLUGIN_DIFY_INNER_API_KEY,
                        # HANDOFF_SHARED_SECRET
```

Also fill in `AZURE_OPENAI_*` and `CHATWOOT_FRONTEND_URL` / `DIFY_CONSOLE_WEB_URL` with the public URLs (`chat.nexaduo.com` and `dify.nexaduo.com`).

### 2. Validate compose

```bash
docker compose config > /dev/null && echo "OK"
```

### 3. Start core infra + Chatwoot init

```bash
docker compose up -d postgres redis
docker compose run --rm chatwoot-init    # runs rails db:chatwoot_prepare once
```

### 4. Start the rest of the stack

```bash
docker compose up -d
docker compose ps    # all healthy in ~2 min (dify-api may take up to 120s in start_period)
```

### 5. First login (manual, one-time)

| Service    | Local URL                | Production URL | What to do |
| ---------- | ------------------------ | -------------- | ---------- |
| Chatwoot   | `http://localhost:3000`  | `chat.nexaduo.com` | Create the super-admin user. Go to *Profile → Access Token* and copy it. |
| Dify       | `http://localhost:3001`  | `dify.nexaduo.com` | Run the setup wizard. Configure **Azure OpenAI** under *Settings → Model Provider*. Create an App (Chatflow/Agent) and copy the **Service API Key**. |
| Evolution  | `http://localhost:8080/manager` | — | Authenticate with `EVOLUTION_AUTHENTICATION_API_KEY`. Create a WhatsApp instance (QR code). |
| Grafana    | `http://localhost:3002`  | — | Login with `GRAFANA_ADMIN_*`. Dashboard "NexaDuo — Chat Services" is pre-provisioned. |
| Prometheus | `http://localhost:9090`  | — | — |

### 6. Connect middleware to Chatwoot and Dify

With tokens copied in the previous step, edit `.env`:

```env
CHATWOOT_API_TOKEN=<Chatwoot admin token>
TENANT_MAP={"1":{"dify_api_key":"app-XXXXXXXX"}}
```

```bash
docker compose up -d middleware
docker compose logs -f middleware    # wait for "middleware: listening" + tenants=1
```

### 7. Register webhook in Chatwoot

In Chatwoot: *Settings → Integrations → Webhooks → Add new webhook*

- URL: `http://middleware.local:4000/webhooks/chatwoot` (Docker network) **or** the middleware public URL
- Events: **Conversation Created**, **Message Created**

### 8. End-to-end test

Send a message through WhatsApp connected to the Evolution instance. Expected flow:

```
WhatsApp → Evolution → Chatwoot conversation (incoming)
        → webhook POST /webhooks/chatwoot
        → middleware → Dify /chat-messages (blocking)
        → response posted to Chatwoot via /messages (outgoing)
        → WhatsApp receives the reply
```

Quick checks:

```bash
curl -s http://localhost:4000/health
curl -s http://localhost:4000/metrics | grep middleware_dify
```

## Human handoff

Dify calls middleware through an HTTP Tool (Dify Studio → *Tools → Custom → HTTP request*):

```http
POST http://middleware.local:4000/tools/handoff
x-handoff-secret: ${HANDOFF_SHARED_SECRET}
Content-Type: application/json

{
  "account_id": "{{chatwoot_account_id}}",
  "conversation_id": "{{chatwoot_conversation_id}}",
  "summary": "Customer wants to cancel their subscription..."
}
```

Effect: the conversation is moved to `open`, receives the `atendimento-humano` label, and a **private note** with the agent summary.

## Repository structure

```
docker-compose.yml                 # Unified stack (Postgres, Redis, Chatwoot, Evolution, Dify, Middleware, Prom/Grafana)
.env.example                       # Secrets template
infrastructure/postgres/           # Init SQL (CREATE DATABASE + pgvector)
middleware/                        # Node 22 / Fastify / TypeScript — Chatwoot ⇄ Dify adapter
dify-apps/                         # Agent YAML (DSL) exports — versioned
provisioning/                      # Tenant onboarding scripts
scripts/                           # backup.sh (daily pg_dump)
observability/                     # prometheus.yml + provisioned Grafana dashboards
docs/plans/first-setup.plan.md     # Blueprint (pt-BR) — architectural source of truth
```

## Pinned versions

| Component | Image |
| :--- | :--- |
| Postgres + pgvector | `pgvector/pgvector:pg16` |
| Redis | `redis:7-alpine` |
| Chatwoot (rails + sidekiq) | `chatwoot/chatwoot:v4.1.0` |
| Evolution API v2 | `atendai/evolution-api:v2.1.1` |
| Dify API / Worker | `langgenius/dify-api:1.13.3` |
| Dify Web | `langgenius/dify-web:1.13.3` |
| Dify Sandbox | `langgenius/dify-sandbox:0.2.14` |
| Dify Plugin Daemon | `langgenius/dify-plugin-daemon:0.5.3-local` |
| Dify SSRF Proxy | `ubuntu/squid:latest` |
| Prometheus | `prom/prometheus:v2.54.1` |
| Grafana | `grafana/grafana:11.3.0` |
| Middleware | local build (`node:22-alpine`) |

> Validate tags in each registry (`docker manifest inspect <img>`) before deploy — upstreams iterate quickly. Keep pins exact.

## Operations

- **Infra requirements:** 4 vCPU / 16 GB RAM (minimum) for shared tier.
- **Backup:** `./scripts/backup.sh` — schedule with cron on the host (see `scripts/README.md`).
- **Observability:** Grafana on `:3002`, dashboard `NexaDuo — Chat Services` pre-provisioned with token usage by `account_id`, Dify latency, and errors.
- **Rate limiting & moderation:** configure directly in Dify (*Orchestrate → Moderation*) and respect Meta tiers.

## Next steps (roadmap)

See `docs/plans/first-setup.plan.md`. Items outside this first iteration:

- **Dedicated** tier (full Dify stack per tenant via compose profile).
- Optional **Weaviate** tier.
- Dify Console API in `create-tenant.sh` (currently semi-manual).
- Postgres/Redis exporter for Prometheus.
- Interactive restore script.
