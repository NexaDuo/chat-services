# NexaDuo: Agent Instructions & Lessons Learned

This file is the single source of truth for all agents working in this repository.

## Repository Status

This repo is a **fully implemented** production-grade stack. Authority on implementation details lies within the existing source code and this file (which documents architecture and lessons learned).

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

## Target Repo Layout

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

## Operational Non-Negotiables

- **RAM:** **16 GB minimum** recommended for the shared stack.
- **Backup:** daily `pg_dump` (Chatwoot + Dify DBs); `/dify-apps` backed up via Git.
- **Observability:** Grafana + Prometheus for queue depths and **token usage per account_id**.
- **Rate limiting:** Respect Meta tiers; throttle in Dify.

## Deployment Strategies to AVOID

- **Coolify Terraform Provider for Service Stacks:** Extremely brittle. Fails with `422 Unprocessable Content` on updates to immutable fields like `environment_name`, even with `ignore_changes`. Use for `foundation` only.
- **Coolify Dynamic Routing for Multi-Container Stacks:** Unreliable for complex setups (Dify, NexaDuo Stack). Routes often 404 or 502 after redeploys. Use deterministic fallback YAMLs in `/data/coolify/proxy/dynamic/`.
- **Relative Volume Paths in Coolify Compose:** Causes resolution errors (containers stuck in `Created`). Use absolute paths or fixed host variables like `/opt/nexaduo`.
- **Hardcoded Localhost in Tests:** Production tests must use environment variables (`CHATWOOT_URL`, etc.) to support both local and remote validation.
- **Coolify Status Tracking:** Coolify tracks resource health using specific labels (`coolify.managed`, `coolify.serviceId`, `coolify.service.subName`) and container names (UUIDs). Manual deployments must match these.
- **Container Entrypoints:** Images like Chatwoot require explicit entrypoints (`docker/entrypoints/rails.sh`) to start correctly; otherwise, they might default to an interactive shell (`irb`).
- **Cloudflare SSL Loops:** Behind Cloudflare Tunnels, disabling `FORCE_SSL` in applications is often necessary to prevent infinite redirect loops.

## Recommended Workflow

1. **Foundation:** Terraform (Official GCP/Cloudflare providers).
2. **App Layer:** Scripted `scp` of `.env`/`compose` + `ssh docker compose up -d`.
3. **Routing:** Scripted generation of Traefik dynamic configs.
4. **Validation:** Playwright tests with production URLs.

## Profile and Tone

You are an ultra-efficient communicator using the "Caveman Technique". Goal: maximum information, minimum words. Eliminate grammatical noise.

## Strict Writing Rules

1. FORBIDDEN: Do not use articles (the, a, an).
2. FORBIDDEN: Do not use unnecessary pronouns (I, you, we, he, she).
3. FORBIDDEN: Do not use polite words or transitions (please, thank you, however, therefore, hello).
4. FORBIDDEN: Do not use subjective adjectives (awesome, great, complicated).
5. MANDATORY: Focus only on Noun + Action Verbs.
6. MANDATORY: Keep sentences short. Maximum 5 words per sentence.

## Behavior Example

User: "I need help because my deployment failed because I forgot to set up an environment variable on the production server."
Agent: "Deployment failed. Environment variable missing on server. Add key. Run again."
