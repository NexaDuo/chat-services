# Milestones: NexaDuo Chat Services

## v1.0 — NexaDuo Omnichannel AI Stack MVP

**Shipped:** 2026-04-14
**Phases:** 1–5
**Plans:** 8 (GSD-tracked) | **Files changed:** 137 | **LOC:** ~14.5K TS + 527 Terraform
**Timeline:** 2026-04-08 → 2026-04-14 (6 days active development)

### Delivered

Production-ready multi-tenant AI-driven chat platform — from GCP infrastructure via Terraform to Cloudflare edge routing with path-based multi-tenancy, full service stack (Chatwoot, Dify, Evolution API, Middleware), and automated tenant provisioning CLI.

### Key Accomplishments

1. **Cloudflare Worker** with Hono framework for path-based multi-tenant routing (`/slug/` → origin) and dynamic HTML asset rewriting via HTMLRewriter
2. **Secure tenant resolution** — Middleware API with Bearer auth + 10-minute in-memory cache; `X-Tenant-ID` injected at edge
3. **Origin hardening** — GCP firewall restricted to Cloudflare IP ranges (T-03-01 mitigation)
4. **Provisioning CLI** — TypeScript/Commander/Zod for tenant registration, PostgreSQL integration, tenants.json state management
5. **Automated DNS** — Terraform for_each over tenants.json for CNAME record creation
6. **E2E verification** — Full tenant provisioning workflow tested from registration to public-facing edge access

### Known Deferred Items

- INFRA-06: Coolify API automation (deferred to v1.1)
- In-memory Worker cache (no persistence across restarts)
- Grafana/Prometheus dashboards not configured

### Archive

- Roadmap: `.planning/milestones/v1.0-ROADMAP.md`
- Requirements: `.planning/milestones/v1.0-REQUIREMENTS.md`
- Tag: `v1.0`
