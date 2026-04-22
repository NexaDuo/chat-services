---
phase: 08
slug: production-provisioning
status: verified
threats_open: 0
asvs_level: 1
created: 2026-04-19
---

# Phase 08 — Security

> Per-phase security contract: threat register, accepted risks, and audit trail.

---

## Trust Boundaries

| Boundary | Description | Data Crossing |
|----------|-------------|---------------|
| User → Edge | Public internet requests to `*.nexaduo.com` handled by Cloudflare | User messages, auth/session metadata |
| Edge → Origin | Cloudflare Worker fetches origin through tunnel/proxy path | Tenant path/header context, webhook/API payloads |

---

## Threat Register

| Threat ID | Category | Component | Disposition | Mitigation | Status |
|-----------|----------|-----------|-------------|------------|--------|
| T-08-04 | Information Disclosure | Edge Traffic | mitigate | TLS at Cloudflare edge with HTTPS-only production endpoints (`chat.nexaduo.com`, `dify.nexaduo.com`) verified in rollout checks | closed |
| T-08-05 | Spoofing | Webhook Requests | mitigate | Middleware validates `X-Chatwoot-Webhook-Token` before processing (`middleware/src/handlers/chatwoot-webhook.ts:62-67`) | closed |
| TF-08-01 | Tampering / Misconfiguration | Coolify proxy fallback route file | accept | `scripts/refresh-coolify-routes.sh` is a privileged operational recovery path documented for controlled use; no direct app-plane exposure | closed |

*Status: open · closed*  
*Disposition: mitigate (implementation required) · accept (documented risk) · transfer (third-party)*

---

## Accepted Risks Log

| Risk ID | Threat Ref | Rationale | Accepted By | Date |
|---------|------------|-----------|-------------|------|
| AR-08-01 | TF-08-01 | Manual fallback route generation is retained for incident recovery when dynamic rebuild fails; execution remains operator-controlled via IAP access. | Phase 08 security audit | 2026-04-19 |

---

## Security Audit Trail

| Audit Date | Threats Total | Closed | Open | Run By |
|------------|---------------|--------|------|--------|
| 2026-04-19 | 3 | 3 | 0 | gsd-secure-phase |

---

## Sign-Off

- [x] All threats have a disposition (mitigate / accept / transfer)
- [x] Accepted risks documented in Accepted Risks Log
- [x] `threats_open: 0` confirmed
- [x] `status: verified` set in frontmatter

**Approval:** verified 2026-04-19
