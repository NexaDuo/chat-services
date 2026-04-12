# Technology Stack Recommendation

**Project:** NexaDuo Chat Services
**Researched:** 2025-01-24

## Recommended Stack

### Core Compute (VM)
| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Hetzner CAX21/31** | ARM64 | Application Hosting | ~€7-12/mo for 4-8 vCPUs and 8-16GB RAM. Best price-to-performance. |
| **GCP e2-standard-4** | x86_64 | Enterprise/GCP Native | Use if GCP credits or organizational policy requires Google Cloud. ~$98/mo. |

### Edge & Routing
| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Cloudflare Workers** | Latest | Multi-tenant Routing | Handles path-to-subdomain mapping and `X-Tenant-ID` header injection at the edge. |
| **Cloudflare Tunnel** | Latest | Secure Connectivity | Exposes Coolify services without opening public ports. |

### Deployment & Orchestration
| Technology | Version | Purpose | Why |
|------------|---------|---------|-----|
| **Coolify** | v4 | Server Management | Self-hosted PaaS that simplifies Docker Compose deployments and Traefik configuration. |
| **Docker Compose** | Latest | App Definition | Industry standard for multi-container apps like Chatwoot and Dify. |

## Alternatives Considered

| Category | Recommended | Alternative | Why Not |
|----------|-------------|-------------|---------|
| Compute | Hetzner ARM | GCP E2 | 10x higher cost for similar performance. |
| Compute | Hetzner ARM | Contabo VPS | Contabo has better "paper" specs but higher "noisy neighbor" risk and slower support. |
| Routing | CF Workers | Nginx/Traefik | CF Workers allow logic to execute closer to the user and simplify header injection before the traffic hits the origin. |

## Installation & Setup

### 1. Cloudflare Worker for Tenant Routing
```typescript
export default {
  async fetch(request, env) {
    const url = new URL(request.url);
    const tenant = url.pathname.split('/')[1]; 
    
    // Rewrite path and inject header
    const newPath = '/' + url.pathname.split('/').slice(2).join('/');
    const modifiedRequest = new Request(url, request);
    modifiedRequest.headers.set('X-Tenant-ID', tenant);
    
    // Fetch from Coolify Origin (via Tunnel or DNS)
    return fetch(`https://origin.yourdomain.com${newPath}`, modifiedRequest);
  }
}
```

### 2. Coolify Docker Compose Fragment
```yaml
networks:
  coolify:
    external: true

services:
  app:
    image: your-image
    networks:
      - coolify
    # Coolify handles the Traefik labels automatically 
    # when you set the FQDN in the UI.
```

## Sources
- [GCP Pricing Calculator](https://cloud.google.com/products/calculator) (Verified 2024-2025)
- [Hetzner Cloud Pricing](https://www.hetzner.com/cloud) (Verified Jan 2025)
- [Chatwoot Deployment Docs](https://www.chatwoot.com/docs/deployment/) (Verified subpath limitations)
