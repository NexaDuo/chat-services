# Security Audit: NexaDuo Chat Services

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
