# Feature Landscape: Multi-tenancy & Routing

**Domain:** Chat & AI Platform
**Researched:** 2025-01-24

## Table Stakes (Expected)

| Feature | Why Expected | Complexity | Notes |
|---------|--------------|------------|-------|
| **Subdomain Isolation** | Standard for SaaS (e.g., `acme.chat.com`). | Low | Supported natively by Chatwoot and Dify. |
| **Edge Header Injection** | Required for the Middleware to know which tenant a request belongs to. | Low | Easily handled by Cloudflare Workers. |
| **Secure Origin Access** | Prevents direct IP access to the database or app. | Low | Solved via Cloudflare Tunnels (Argo). |

## Differentiators

| Feature | Value Proposition | Complexity | Notes |
|---------|-------------------|------------|-------|
| **Path-based Multi-tenancy** | Use one domain (e.g., `chat.com/acme`) for all tenants. | **High** | Requires custom builds for Dify and is NOT recommended for Chatwoot. |
| **Geo-specific Routing** | Route `tenant-eu.chat.com` to EU servers and `tenant-us` to US servers. | Medium | CF Workers can detect `request.cf.country`. |
| **Instant Provisioning** | Auto-generating a new tenant environment in Coolify via API. | High | Requires integration between App and Coolify API. |

## Anti-Features (Avoid)

| Anti-Feature | Why Avoid | What to Do Instead |
|--------------|-----------|-------------------|
| **Chatwoot Subpath** | Extremely brittle; breaks assets and WebSockets. | Use subdomains (`tenant.chat.com`). |
| **Direct DB Exposure** | High security risk. | Use Middleware as the sole gatekeeper for data modifications. |
| **Manual SSL Config** | High maintenance overhead. | Use Cloudflare Proxy + Coolify/Traefik auto-SSL. |

## Feature Dependencies
```
Cloudflare DNS → Cloudflare Worker → Cloudflare Tunnel → Coolify Proxy → App
```

## MVP Recommendation

Prioritize:
1. **Subdomain-based routing** using Cloudflare Workers for header injection.
2. **Hetzner ARM hosting** for cost efficiency.
3. **Cloudflare Tunnel** for origin security.

Defer:
- **Path-based routing**: The complexity of rebuilding Dify images and the lack of Chatwoot support makes this a low-ROI effort initially.

## Sources
- [Dify GitHub Issues regarding subpaths](https://github.com/langgenius/dify/issues)
- [Chatwoot Community Discussions](https://github.com/chatwoot/chatwoot/discussions)
