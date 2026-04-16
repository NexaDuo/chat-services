---
updated_at: "2026-04-16T17:00:00.000Z"
---

## Architecture Overview

NexaDuo is a multi-tenant omnichannel AI stack designed for low-cost, high-scale customer service. It leverages an adapter-based architecture where a central **Middleware** acts as the glue between **Chatwoot** (CRM/Inbox) and **Dify** (AI Engine). Multi-tenancy is handled at the edge using **Cloudflare Workers**, allowing multiple clients to share the same infrastructure via path-based routing (`chat.nexaduo.com/{tenant}/`).

The stack is orchestrated via **Coolify** on a single GCP VM, managed with **Terraform**. Security is being hardened in Phase 6 with **GCP Secret Manager** for centralized secret management.

## Key Components

| Component | Path | Responsibility |
|-----------|------|---------------|
| Middleware | `middleware/` | Adapts Chatwoot webhooks to Dify API; manages tenant resolution and human handoff tools. |
| Edge Router | `edge/cloudflare-worker/` | Cloudflare Worker that handles path-based routing, asset rewriting, and `X-Tenant-ID` header injection. |
| Provisioning CLI | `provisioning/` | Automates tenant creation, database setup, and reachability validation. |
| Infrastructure | `infrastructure/terraform/` | Defines GCP resources (VM, Storage, Secret Manager) and Cloudflare configurations (DNS, Tunnels). |
| Observability | `observability/` | Provisioning for Prometheus, Grafana, Loki, and Promtail. |
| Self-Healing Agent | `agents/self-healing/` | Specialized agent for monitoring and automatic recovery of stack services. |

## Data Flow

**Inbound Message:**
`WhatsApp` -> `Evolution API` -> `Chatwoot (conversation)` -> `Middleware (webhook)` -> `Dify (AI agent)` -> `Middleware (response)` -> `Chatwoot (reply)` -> `Evolution API` -> `WhatsApp`

**Edge Routing:**
`User Request (path-based)` -> `Cloudflare Worker` -> `Resolve Tenant ID` -> `Inject X-Tenant-ID Header` -> `Proxy to Origin (GCP VM)` -> `Coolify/Docker Compose`

## Conventions

- **Multi-tenancy:** Uses `X-Tenant-ID` header to distinguish traffic within the shared Chatwoot/Dify instances.
- **Project Structure:** Component-based directory structure (`middleware/`, `provisioning/`, `edge/`).
- **Configuration:** Environment-variable driven, migrating to GCP Secret Manager.
- **Language:** TypeScript for all custom code, utilizing Fastify for performance and Hono for edge execution.
- **Infrastructure:** Modular Terraform for cross-provider orchestration.
