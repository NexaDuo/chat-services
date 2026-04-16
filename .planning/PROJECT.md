# Project: NexaDuo Chat Services

## Core Value
Building a low-cost, multi-tenant AI-driven chat platform leveraging Chatwoot, Dify, and Evolution API, orchestrated via Coolify and routed through Cloudflare to provide seamless, scalable experiences for multiple tenants on a single-node origin.

The platform distinguishes itself through:
- **Autonomous Error Recovery:** Integrated Self-Healing Agent that monitors logs and uses LLMs to suggest/apply fixes.
- **Human-in-the-Loop:** Seamless handoff from AI agents to human operators within Chatwoot.
- **Edge-Based Multi-tenancy:** High-performance tenant resolution at the Cloudflare edge.

## Tech Stack
- **Infrastructure:** GCP (Google Cloud Platform)
- **Infrastructure as Code:** Terraform
- **Orchestration:** Coolify (Docker Engine/Compose based)
- **Edge Routing:** Cloudflare DNS, Tunnels (Argo), and Workers
- **Core Applications:** 
  - **Chatwoot:** Omnichannel customer engagement platform.
  - **Dify:** AI application development platform for RAG and Agentic workflows.
  - **Evolution API:** Open-source messaging connector for WhatsApp and others.
  - **Middleware:** Custom Fastify bridge for tenant resolution, data transformation, and human handoff.
  - **Self-Healing Agent:** Custom Node.js service for automated log analysis (Loki) and LLM-driven diagnosis.
- **Database:** Postgres + pgvector, Redis
- **Observability:** Prometheus, Grafana, Loki, Promtail, OTEL Collector
- **Language:** TypeScript (Middleware, Edge, Agents, Provisioning)

## Constraints
- **Low-Cost Goal:** Use cost-efficient GCP instance types (e2-standard-4) and single-node orchestration to minimize overhead.
- **Path-based Routing:** Tenants are accessed via paths on unified subdomains: `chat.nexaduo.com/{tenant}/` (Chatwoot) and `dify.nexaduo.com/{tenant}` (Dify). This is managed via Cloudflare Workers at the edge to route to internal shared instances.
- **Portless Ingress:** Use Cloudflare Tunnels (Argo) to secure the origin and avoid opening firewall ports (except SSH).
- **Single Provider:** Stick to GCP as the primary cloud provider (based on initial hosting plan).
