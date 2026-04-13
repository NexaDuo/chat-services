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
- **Subdomain Routing:** Avoid path-based routing (e.g., `/tenant/app`) for Chatwoot due to known breakage; use `{tenant}.chat.nexaduo.com` instead.
- **Portless Ingress:** Use Cloudflare Tunnels (Argo) to secure the origin and avoid opening firewall ports (except SSH).
- **Single Provider:** Stick to GCP as the primary cloud provider (based on initial hosting plan).
