# Domain Pitfalls: Hosting & Multi-tenancy

**Domain:** Chatwoot/Dify Hosting
**Researched:** 2025-01-24

## Critical Pitfalls

### Pitfall 1: Chatwoot Subpath "Wall"
**What goes wrong:** Attempting to host Chatwoot at `domain.com/chat` leads to 404s for JS/CSS assets and "Connection Failed" for WebSockets (ActionCable).
**Why it happens:** The Vue.js frontend is hardcoded to root paths, and Rails ActionCable requires specific proxy header tuning for subpaths.
**Consequences:** Broken UI and no real-time message updates.
**Prevention:** **Always use subdomains** (e.g., `chat.domain.com`) for Chatwoot.
**Detection:** Check browser console for `GET /assets/... 404` errors.

### Pitfall 2: Dify Frontend Build Requirements
**What goes wrong:** Setting `NEXT_PUBLIC_BASE_PATH` in `.env` for Dify doesn't work.
**Why it happens:** Next.js injects base paths at **build time**, not runtime.
**Consequences:** Frontend links and assets remain pointed to root.
**Prevention:** Rebuild the `dify-web` Docker image with `--build-arg NEXT_PUBLIC_BASE_PATH=/yourpath`.
**Detection:** URL bar shows `/yourpath` but page is blank or assets fail to load.

### Pitfall 3: Resource Spikes on ARM
**What goes wrong:** Dify's Vector Database (Weaviate/Qdrant) or Sidekiq workers can spike RAM usage, causing OOM kills on 8GB instances.
**Why it happens:** Initial indexing or high-volume webhook bursts.
**Consequences:** Service downtime.
**Prevention:** Configure at least **4GB of Swap space** on the SSD, even on 16GB RAM machines.
**Detection:** `dmesg | grep -i oom` or monitor RAM usage in Grafana.

## Moderate Pitfalls

### Pitfall 1: Cloudflare Worker Header Trust
**What goes wrong:** Security bypass if the backend trusts the `X-Tenant-ID` header without verification.
**Prevention:** Use a shared secret (e.g., `X-Worker-Signature`) that the Worker adds and the Middleware verifies.

## Phase-Specific Warnings

| Phase Topic | Likely Pitfall | Mitigation |
|-------------|---------------|------------|
| **Multi-tenancy** | WebSocket disconnection | Ensure Cloudflare "WebSockets" toggle is ON and Workers handle `Upgrade` headers. |
| **GCP Migration** | Egress Costs | Monitor bandwidth; GCP charges significantly for data leaving the region compared to flat-rate VPS providers. |

## Sources
- [Chatwoot GitHub Issue #1234 (Subpath support)](https://github.com/chatwoot/chatwoot/issues)
- [Dify Documentation: Environment Variables](https://docs.dify.ai/deployment/docker-compose)
