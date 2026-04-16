# Security Policy

## Reporting a Vulnerability

If you discover a potential security vulnerability in this project, please report it immediately to [security@nexaduo.com.br](mailto:security@nexaduo.com.br).

**Please do not open a public issue.** We will acknowledge your report within 48 hours and provide a timeline for a fix.

---

# Security Audit: NexaDuo Chat Services

## Phase 07: Repository Hardening
**Audit Date:** 2026-04-16
**Status:** 3/3 Mitigations Verified

### Verified Mitigations
- **[T-07-04] Spoofing (Chatwoot Webhook):**
  - **Mitigation:** Middleware validates the `X-Chatwoot-Webhook-Token` header against `CHATWOOT_WEBHOOK_TOKEN` env var.
  - **Evidence:** Implemented in `middleware/src/handlers/chatwoot-webhook.ts`.
- **[T-07-05] Information Disclosure (Postgres/Redis):**
  - **Mitigation:** Public port mappings for Postgres (5432) and Redis have been removed. Services are only accessible via the internal Docker network.
  - **Evidence:** Modified `deploy/docker-compose.shared.yml`.
- **[T-07-06] Tampering (Dify Plugins):**
  - **Mitigation:** Dify plugin-daemon now enforces signature verification for all installed plugins.
  - **Evidence:** Set `FORCE_VERIFYING_SIGNATURE: "true"` in `deploy/docker-compose.dify.yml`.

## Phase 03: Edge Logic & Path Routing
**Audit Date:** 2026-04-14
**Status:** 2/3 Mitigations Verified

### Verified Mitigations
- **[T-03-02] Information Disclosure (Middleware API):** 
  - **Mitigation:** `/resolve-tenant` endpoint is protected by a 32-character `SHARED_SECRET` using `Bearer` token authentication.
  - **Evidence:** Implemented in `edge/cloudflare-worker/src/index.ts` and `middleware/src/handlers/tenant.ts`.
- **[T-03-03] Denial of Service (Resolution Latency):**
  - **Mitigation:** Cloudflare Worker implements a 10-minute in-memory cache (`TENANT_CACHE`) for slug-to-ID mapping.
  - **Evidence:** Implemented in `edge/cloudflare-worker/src/index.ts`.

### Open Threats & Risks
- **[T-03-01] Spoofing (Header Injection):**
  - **Risk:** If the origin IP or hostname is discovered, an attacker could bypass the Cloudflare Worker and inject their own `X-Tenant-ID` headers to access other tenant data.
  - **Status:** **OPEN**. Origin services (Chatwoot/Dify) are currently accessible via Cloudflare Tunnels, but do not yet explicitly verify that requests *must* originate from the Worker.
  - **Recommendation:** Implement Cloudflare Authenticated Origin Pulls (mTLS) or restrict origin ingress to Cloudflare's IP ranges at the firewall/load-balancer level.

## Security Log
- 2026-04-14: Phase 03 Security Audit completed. 1 open risk identified regarding origin-side header verification.
- 2026-04-16: Phase 07 Security Audit completed. 3 mitigations verified for webhook security and ingress hardening.
