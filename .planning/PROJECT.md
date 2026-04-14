# Project: NexaDuo Chat Services

## Core Value
Building a low-cost, multi-tenant AI-driven chat platform leveraging Chatwoot, Dify, and Evolution API, orchestrated via Coolify and routed through Cloudflare to provide seamless, scalable experiences for multiple tenants on a single-node origin.

## Tech Stack
- **Infrastructure:** GCP (Google Cloud Platform)
- **Infrastructure as Code:** Terraform
- **Orchestration:** Coolify (Docker Engine/Compose based)
- **Edge Routing:** Cloudflare DNS, Tunnels, and Workers
- **Core Applications:** Chatwoot (customer service), Dify (AI orchestration), Evolution API (messaging)
- **Database:** Postgres + pgvector, Redis
- **Observability:** Prometheus, Grafana, Loki, Promtail, OTEL Collector
- **Language:** TypeScript (Middleware, Agents)

## Constraints
- **Low-Cost Goal:** Use cost-efficient GCP instance types (e2-standard-4) and single-node orchestration to minimize overhead.
- **Path-based Routing:** Tenants are accessed via paths on unified subdomains: `chat.nexaduo.com/{tenant}/` (Chatwoot) and `dify.nexaduo.com/{tenant}` (Dify). This is managed via Cloudflare Workers at the edge to route to internal shared instances.
- **Portless Ingress:** Use Cloudflare Tunnels (Argo) to secure the origin and avoid opening firewall ports (except SSH).
- **Single Provider:** Stick to GCP as the primary cloud provider (based on initial hosting plan).
