# External Integrations

**Analysis Date:** 2025-01-24

## APIs & External Services

**Chat Hub:**
- Chatwoot - Omnichannel customer service hub.
  - SDK/Client: Axios (Custom client in `middleware/src/chatwoot.ts`).
  - Auth: `CHATWOOT_API_TOKEN`.

**LLM Orchestration:**
- Dify - Agent and RAG platform.
  - SDK/Client: Axios (Custom client in `middleware/src/dify.ts`).
  - Auth: `DIFY_API_KEY` (per-tenant) and `DIFY_SELF_HEALING_API_KEY`.

**Messaging Gateway:**
- Evolution API - Bridge for WhatsApp and Instagram.
  - Auth: `EVOLUTION_AUTHENTICATION_API_KEY`.

## Data Storage

**Databases:**
- PostgreSQL 16 (shared)
  - Connection: `DATABASE_URL` / `POSTGRES_HOST`.
  - Client: `pg` (custom logic) and ORM-less raw SQL in custom services.

**Vector Store:**
- pgvector (via shared PostgreSQL) - Used by Dify for RAG.

**Caching:**
- Redis 7 (shared)
  - Connection: `REDIS_URL`.

**File Storage:**
- Local filesystem (via Docker volumes).

## Authentication & Identity

**Auth Provider:**
- Custom / Shared Secret
  - Implementation: `HANDOFF_SHARED_SECRET` used for service-to-service communication between `middleware` and `self-healing-agent`.

## Monitoring & Observability

**Metrics:**
- Prometheus - Scrapes metrics from `/metrics` endpoints.
- OpenTelemetry (OTEL) - Used by Dify to push traces/metrics.

**Logs:**
- Loki - Log aggregation service.
- Promtail - Log scraping agent for Docker.

**Dashboards:**
- Grafana - Visualization for metrics, logs, and database insights.

## CI/CD & Deployment

**Hosting:**
- Docker Compose based, typically behind a reverse proxy (Coolify/Traefik).

**CI Pipeline:**
- Not explicitly configured in the repo (standard Docker build).

## Environment Configuration

**Required env vars:**
- `POSTGRES_USER`, `POSTGRES_PASSWORD`
- `CHATWOOT_API_TOKEN`, `CHATWOOT_SECRET_KEY_BASE`
- `DIFY_SECRET_KEY`, `DIFY_SANDBOX_API_KEY`
- `EVOLUTION_AUTHENTICATION_API_KEY`
- `HANDOFF_SHARED_SECRET`

**Secrets location:**
- Managed via `.env` file and passed to containers.

## Webhooks & Callbacks

**Incoming:**
- `middleware/`: `/webhooks/chatwoot` - Receives incoming messages from Chatwoot.
- `middleware/`: `/handoff` - Receives handoff requests from Dify tools.

**Outgoing:**
- Chatwoot API calls (post messages).
- Dify API calls (chat/agent requests).

---

*Integration audit: 2025-01-24*
