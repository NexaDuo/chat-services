<!-- generated-by: gsd-doc-writer -->
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository status

This repo is a **fully implemented** production-grade stack. Authority on implementation details lies within the existing source code and the `AGENTS.md` file (which documents lessons learned).

## Architecture (target state)

The system is a four-service stack with **Chatwoot as the single hub** for all conversations:

```
WhatsApp ──▶ Evolution API ──▶ Chatwoot (Webhook) ──▶ Middleware (Adapter) ──▶ Dify (Agent) ──▶ Azure OpenAI
                                      ▲                      │
                                      └─────── response ─────┘
```

- **Coolify** — [coolify.nexaduo.com](https://coolify.nexaduo.com) (Orquestração e Deploy via Bash/Docker).
- **Chatwoot** — [chat.nexaduo.com](https://chat.nexaduo.com). Inbox, CRM, ticketing, human handoff. Single source of truth.
- **Dify** — [dify.nexaduo.com](https://dify.nexaduo.com). Agentic engine + RAG. Supports MCP bidirectionally.
- **Evolution API v2.1+** — WhatsApp/Instagram bridge.
- **Middleware (Adapter)** — Node.js service that translates Chatwoot webhooks to Dify API calls and sends responses back to Chatwoot. Centralized config provider for internal agents.
- **Self-Healing Agent** — Node.js agent that analyzes Loki logs via Dify to find root causes of errors.
- **Observability** — Loki, Promtail, Prometheus, and Grafana (centralized logs and metrics).
- **Postgres 16+** — shared by Chatwoot, Dify, and Middleware via separate databases.
- **pgvector** — **Primary vector store** (reuses Postgres).
- **Redis 7+** — Sidekiq (Chatwoot) + Celery (Dify) queues.
- **Azure OpenAI** — `gpt-4o` (agent) and `gpt-4o-mini` (embeddings/RAG).

**Human handoff** is a Dify **tool** (HTTP request) that updates the Chatwoot conversation status to `open` and adds the `atendimento-humano` label.

## Deployment Strategy

The stack uses a **Hybrid Deployment Model**:
1. **Foundation (Terraform):** Mature infrastructure components (GCP VM, VPC, Cloudflare Tunnel/DNS, Secrets) are managed via Terraform in `infrastructure/terraform/envs/production/foundation`.
2. **App Layer (Bash/Docker):** Services are deployed directly via `scripts/deploy-tenant-direct.sh`, which uses SCP/SSH to transfer configurations and start Docker Compose on the VM. This bypasses instabilities in the Coolify Terraform provider.

## Configuration & Dynamics

The stack uses a **hybrid configuration model**:
1. **Static (.env):** Infrastructure secrets (DB passwords, Redis URLs, etc.).
2. **Dynamic (Postgres + Middleware API):** Application-specific settings and API keys (e.g., `DIFY_SELF_HEALING_API_KEY`).

**Standard for internal agents:**
- All internal agents (like `self-healing`) must fetch their functional configuration from the **Middleware Config API** (`GET /config`).
- Authentication for internal config fetching is done via `Bearer token` using the `HANDOFF_SHARED_SECRET`.
- New configuration keys should be added to the `middleware.configs` table in Postgres for runtime updates.

## Target repo layout

```
docker-compose.yml           # Base stack
.env.example                 # Secrets template
/deploy                      # Multi-stack docker-compose configurations
/middleware                  # Dify-Chatwoot Adapter (Node.js/TS)
/infrastructure/postgres     # Init: DB creation + pgvector extension
/infrastructure/terraform    # Foundation and Tenant IaC
/dify-apps                   # DSL (YAML) exports of agents - MUST be versioned
/provisioning                # Automation scripts
/scripts                     # Deploy utilities
/onboarding                  # Playwright automation and smoke tests
```

## Operational non-negotiables

- **RAM:** **16 GB minimum** recommended for the shared stack.
- **Backup:** daily `pg_dump` (Chatwoot + Dify DBs); `/dify-apps` backed up via Git.
- **Observability:** Grafana + Prometheus for queue depths and **token usage per account_id**.
- **Rate limiting:** Respect Meta tiers; throttle in Dify.

## Language

`plan.md` is in pt-BR. Keep documentation in pt-BR; code and config in English. Default to Portuguese for user interactions.
