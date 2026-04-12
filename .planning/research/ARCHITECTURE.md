# Architecture Patterns: Hosting & Multi-tenancy

**Domain:** Chatwoot/Dify Infrastructure
**Researched:** 2025-01-24

## Recommended Architecture

The system utilizes a **Hybrid Edge-Origin Architecture**. Cloudflare handles the edge (routing, security, tenant identification) while Coolify manages the origin (Docker orchestration, local proxy).

### Component Boundaries

| Component | Responsibility | Communicates With |
|-----------|---------------|-------------------|
| **Cloudflare Worker** | Tenant identification from path/domain; Header injection. | Internet, Coolify Origin |
| **Cloudflare Tunnel** | Secure ingress to the origin without open ports. | CF Worker, Coolify Proxy |
| **Coolify Proxy (Traefik)** | Internal routing between Docker containers. | CF Tunnel, App Containers |
| **Chatwoot/Dify** | Core application logic and multi-tenant isolation. | Database, Redis, Middleware |

### Data Flow

1. **User Request:** Hits Cloudflare Edge via `tenant1.chat.com`.
2. **Worker Logic:** Identifies `tenant1`, adds `X-Tenant-ID: 1` header, and passes request to origin.
3. **Argo Tunnel:** Securely delivers the request to the `cloudflared` container on the server.
4. **Coolify Proxy:** Receives traffic from `cloudflared` and routes it to the correct Docker service based on the hostname.
5. **Application:** Receives the request + injected tenant header and processes accordingly.

## Patterns to Follow

### Pattern 1: Edge Header Injection
**What:** Using Workers to inject context before traffic hits the origin.
**When:** For multi-tenancy where the backend needs to know the tenant identity without parsing URLs itself.
**Example:**
```typescript
const modifiedRequest = new Request(url, request);
modifiedRequest.headers.set('X-Tenant-ID', resolvedTenantId);
return fetch(url, modifiedRequest);
```

### Pattern 2: Secure Origin (Portless)
**What:** Disabling all inbound ports (80/443/22) except for those required by the Cloudflare Tunnel.
**When:** Production environments needing protection against DDoS and direct IP scanners.

## Anti-Patterns to Avoid

### Anti-Pattern 1: Subpath Routing for Chatwoot
**What:** Using `domain.com/tenant-a/chatwoot`.
**Why bad:** Chatwoot's frontend assets and ActionCable (WebSockets) are notoriously difficult to configure for subpaths, leading to broken interfaces.
**Instead:** Use `tenant-a.chatwoot.domain.com`.

## Sources
- [Cloudflare Workers Documentation](https://developers.cloudflare.com/workers/)
- [Coolify Cloudflare Integration Guide](https://coolify.io/docs/cloudflare)
