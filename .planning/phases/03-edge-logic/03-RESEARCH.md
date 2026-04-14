# Phase 3: Edge Logic & Path Routing - Research

**Researched:** 2026-04-14
**Domain:** Cloudflare Workers / Edge Routing
**Confidence:** HIGH

## Summary
Phase 3 implements the intelligent edge layer using Cloudflare Workers. This layer is responsible for multi-tenant routing based on URL paths (`/tenant/`), injecting the `X-Tenant-ID` header, and proxying requests to the appropriate backend services (Chatwoot and Dify). 

**Primary recommendation:** Use a Hono-based Cloudflare Worker for clean routing and middleware support. Implement a caching layer (KV or in-memory) for tenant resolution to avoid hitting the Middleware API on every request.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Hono | 4.12.12 | Web Framework | Extremely fast, small footprint, excellent for Workers. |
| Wrangler | 3.x | CLI Tooling | Official Cloudflare tool for development and deployment. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| Cloudflare KV | — | Caching | Storing tenant resolution results (slug -> account_id). |

## Architecture Patterns

### Path Extraction & Stripping
To route `chat.nexaduo.com/alpha/app` to the backend as `/app` with `X-Tenant-ID: alpha`:
1. Extract `alpha` from `url.pathname.split('/')[1]`.
2. Rewrite `url.pathname` by removing the first segment.
3. Inject `X-Tenant-ID: alpha` into the request headers.

### WebSocket Proxying
Chatwoot uses ActionCable for real-time updates. Cloudflare Workers handle this via the standard `fetch` API:
```javascript
const upgradeHeader = request.headers.get('Upgrade');
if (upgradeHeader === 'websocket') {
  return fetch(targetUrl, request);
}
```

## Interaction with Middleware
The Middleware service provides a `/resolve-tenant` endpoint.
- **Request:** `GET /resolve-tenant?subdomain={tenant}`
- **Auth:** `Bearer {shared_secret}`
- **Response:** `{ accountId: "..." }`

## Common Pitfalls
- **Host Header:** Must be set to the backend origin's hostname (e.g., `chat-origin.nexaduo.com`) to avoid 403/SSL errors.
- **Trailing Slashes:** Inconsistent handling of `/tenant` vs `/tenant/` can break asset loading.
- **ActionCable Path:** Ensure the worker correctly handles `/cable` or `{tenant}/cable` paths.

## Environment Availability
- **Node.js/npm:** Available (v20.16.0 / 10.8.1).
- **Wrangler:** Available via npm (verified version 4.82.2 in registry).
- **Postgres:** Available (required for Middleware which the Worker calls).

## Code Example (Hono)
```typescript
const app = new Hono();

app.all('/:tenant/*', async (c) => {
  const tenant = c.req.param('tenant');
  const url = new URL(c.req.url);
  
  // Path Stripping
  url.pathname = url.pathname.replace(`/${tenant}`, '') || '/';
  
  const newRequest = new Request(url, c.req.raw);
  newRequest.headers.set('X-Tenant-ID', tenant);
  newRequest.headers.set('Host', ORIGIN_HOSTNAME);
  
  return fetch(newRequest);
});
```

## Assumptions Log
| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Cloudflare Tunnels can be targeted by Workers via public hostnames. | Summary | Medium - Tunnels must have public hostnames configured. |
| A2 | Chatwoot's frontend doesn't strictly require `RAILS_RELATIVE_URL_ROOT` if the Worker strips correctly. | Architecture | High - May require `HTMLRewriter` to fix absolute paths in HTML. |

**Next Steps:**
1. Create a detailed execution plan for Phase 3 (03-01-PLAN.md).
2. Set up the Cloudflare Worker project using Hono.
3. Implement the routing and header injection logic.
4. Test with Chatwoot and Dify origins.
