# External Integrations

**Analysis Date:** 2026-04-14

## APIs & External Services

**Chat Hub:**
- Chatwoot - Omnichannel customer service.
  - SDK/Client: Axios (Middleware).
  - Auth: `CHATWOOT_API_TOKEN`.

**AI Orchestration:**
- Dify - RAG and Agent engine.
  - SDK/Client: Axios (Middleware).
  - Auth: Per-tenant API keys.

**Edge & Connectivity:**
- Cloudflare Tunnel (Argo) - Portless origin connectivity.
- Cloudflare Workers (Deferred/Planned) - Path-based edge routing.

## Data Storage

**Databases:**
- PostgreSQL 16 (on-instance via Docker).
  - Client: `pg` (Node.js).
  - Features: `pgvector` for AI similarity search.

**Caching:**
- Redis 7 (on-instance via Docker).
  - Used by: Chatwoot Sidekiq, Dify Celery.

**File Storage:**
- Google Cloud Storage (GCS) - Backup and Terraform remote state.
- Local filesystem (via Docker volumes).

## Authentication & Identity

**Auth Provider:**
- Custom Shared Secret (`HANDOFF_SHARED_SECRET`) for internal service calls.
- API Key based auth for external service SDKs.

## Monitoring & Observability

**Error Tracking & Logs:**
- Loki - Log aggregation.
- Promtail - Log scraping.
- Grafana - Visualization.

**Metrics:**
- Prometheus - Metric scraping from app endpoints (`/metrics`).

## CI/CD & Deployment

**Hosting:**
- Google Cloud Platform (GCP) Compute Engine.
- Coolify v4 for container orchestration.

**IaC:**
- Terraform for GCP VM, GCS, Cloudflare DNS, and Cloudflare Tunnels.

## Environment Configuration

**Required env vars:**
- `GCP_PROJECT_ID`, `CLOUDFLARE_API_TOKEN` (Terraform).
- `DATABASE_URL`, `REDIS_URL` (Middleware/Apps).
- `CHATWOOT_API_TOKEN`, `DIFY_API_KEY` (Middleware).

**Secrets location:**
- GCP Secret Manager (Planned) / `.env` (Current).

## Webhooks & Callbacks

**Incoming:**
- `middleware:3001/webhooks/chatwoot` - Message events.
- `middleware:3001/handoff` - Dify tool calls.

**Outgoing:**
- Messaging events to external Chatwoot/Dify endpoints via Cloudflare Tunnel.

---

*Integration audit: 2026-04-14*
