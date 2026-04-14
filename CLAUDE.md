<!-- generated-by: gsd-doc-writer -->
# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository status

This repo is currently **blueprint-only**. The only substantive file is `plan.md` (in Portuguese) — the technical blueprint for an Omnichannel AI Stack. Treat `plan.md` as the authoritative source of architectural intent.

## Architecture (target state)

The system is a four-service stack with **Chatwoot as the single hub** for all conversations:

```
WhatsApp ──▶ Evolution API ──▶ Chatwoot (Webhook) ──▶ Middleware (Adapter) ──▶ Dify (Agent) ──▶ Azure OpenAI
                                      ▲                      │
                                      └─────── response ─────┘
```

- **Coolify** — [coolify.nexaduo.com](https://coolify.nexaduo.com) (Orquestração e Deploy).
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

## Configuration & Dynamics

The stack uses a **hybrid configuration model**:
1. **Static (.env):** Infrastructure secrets (DB passwords, Redis URLs, etc.).
2. **Dynamic (Postgres + Middleware API):** Application-specific settings and API keys (e.g., `DIFY_SELF_HEALING_API_KEY`).

**Standard for internal agents:**
- All internal agents (like `self-healing`) must fetch their functional configuration from the **Middleware Config API** (`GET /config`).
- Authentication for internal config fetching is done via `Bearer token` using the `HANDOFF_SHARED_SECRET`.
- New configuration keys should be added to the `middleware.configs` table in Postgres for runtime updates.

## Multitenancy model

1. **Tier Shared (default)** — one Dify CE, one app per client. Chatwoot `account_id` maps to a `DIFY_API_KEY` in the middleware.
2. **Tier Dedicated** — full Dify stack per tenant.

**Routing Strategy (Future):**
- **Chatwoot:** `chat.nexaduo.com/{tenant}/`
- **Dify:** `dify.nexaduo.com/{tenant}/`

**Conversational memory key:** Dify is called with `user = {account_id}:{contact_id}` from Chatwoot.

## Target repo layout

```
docker-compose.yml           # Base stack
.env.example                 # Secrets template
/middleware                  # Dify-Chatwoot Adapter (Node.js/TS)
/infrastructure/postgres     # Init: DB creation + pgvector extension
/dify                        # Dify-specific docker configs
/dify-apps                   # DSL (YAML) exports of agents - MUST be versioned
/provisioning                # Automation scripts
/scripts                     # Deploy utilities (Coolify-ready)
```

## Operational non-negotiables

- **RAM:** **16 GB minimum** recommended for the shared stack.
- **Backup:** daily `pg_dump` (Chatwoot + Dify DBs); `/dify-apps` backed up via Git.
- **Observability:** Grafana + Prometheus for queue depths and **token usage per account_id**.
- **Rate limiting:** Respect Meta tiers; throttle in Dify.

## Language

`plan.md` is in pt-BR. Keep documentation in pt-BR; code and config in English. Default to Portuguese for user interactions.
