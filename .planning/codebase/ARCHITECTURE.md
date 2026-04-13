# Architecture

**Analysis Date:** 2025-01-24

## Pattern Overview

**Overall:** Hexagonal/Adapter Architecture with Distributed Observability.

The system is designed as a set of loosely coupled services that communicate over HTTP and share a single persistence layer. It acts as an adapter between a customer service platform (Chatwoot) and an AI agent engine (Dify).

**Key Characteristics:**
- **Centralized Adapter**: Middleware translates external events into LLM-compatible requests.
- **Asynchronous Monitoring**: Self-healing agents watch logs and metrics out-of-band to provide insights without affecting the request path.
- **Shared Persistence**: A single robust PostgreSQL instance serves as the backbone for all services, simplifying state management and data analysis.

## Layers

**Communication Layer:**
- Purpose: Handles incoming and outgoing messages across different channels (WhatsApp/Instagram).
- Location: `evolution-api` (Docker service).
- Contains: Messaging protocol adapters.
- Depends on: PostgreSQL, Redis.
- Used by: Chatwoot.

**Orchestration Layer:**
- Purpose: Central inbox and CRM for human and bot interactions.
- Location: `chatwoot-rails` / `chatwoot-sidekiq` (Docker services).
- Contains: Inboxes, agents, labels, and workflow rules.
- Depends on: PostgreSQL, Redis.
- Used by: Middleware (via webhooks).

**Adapter Layer (Custom):**
- Purpose: Bridges Chatwoot and Dify, handling tenant mapping and response posting.
- Location: `middleware/src`
- Contains: Webhook handlers, API clients, and metrics exporters.
- Depends on: Dify, Chatwoot, PostgreSQL.
- Used by: Chatwoot (webhooks), Dify (handoff tools).

**Cognitive Layer:**
- Purpose: Executes LLM agents and provides RAG capabilities.
- Location: `dify-api` / `dify-worker` (Docker services).
- Contains: Workflow definitions, prompts, and vector store indexing.
- Depends on: PostgreSQL (pgvector), Redis.
- Used by: Middleware, Self-Healing Agent.

**Observability Layer:**
- Purpose: Aggregates logs, metrics, and insights for stack health.
- Location: `observability/`
- Contains: Prometheus, Loki, Grafana, Promtail.
- Depends on: All other services for data.
- Used by: Administrators and the Self-Healing Agent.

## Data Flow

**Standard Chat Flow:**
1. External message → `evolution-api` → Chatwoot.
2. Chatwoot → Webhook → `middleware/src/handlers/chatwoot-webhook.ts`.
3. Middleware → `dify.ts` (Dify API) → Agent execution.
4. Dify response → Middleware → Chatwoot API → External user.

**Self-Healing Flow:**
1. All services → Logs → `promtail` → `loki`.
2. `self-healing-agent/src/index.ts` polls Loki for "error" logs.
3. Agent → Dify API (Analysis Workflow) → LLM Insight.
4. Agent → PostgreSQL (`insights` table).
5. Grafana → PostgreSQL → Visual Insight for human operator.

## Key Abstractions

**Tenant Resolver:**
- Purpose: Maps Chatwoot account IDs to Dify API keys and endpoints.
- Examples: `middleware/src/config.ts` (`resolveTenant`).

**Conversation Memory Bridge:**
- Purpose: Persists Dify's `conversation_id` into Chatwoot's `custom_attributes` to ensure session continuity across turns.
- Examples: `middleware/src/handlers/chatwoot-webhook.ts`.

## Entry Points

**Chatwoot Webhook:**
- Location: `middleware/src/handlers/chatwoot-webhook.ts` (`/webhooks/chatwoot`)
- Triggers: Incoming message in Chatwoot.
- Responsibilities: Validation, tenant mapping, Dify orchestration.

**Handoff Endpoint:**
- Location: `middleware/src/handlers/handoff.ts` (`/handoff`)
- Triggers: Dify workflow tool call for human intervention.
- Responsibilities: Labeling conversation as `atendimento-humano` in Chatwoot.

## Error Handling

**Strategy:** Fail-soft with operator notification.

**Patterns:**
- **Private Notes**: Middleware posts private notes in Chatwoot when Dify calls fail, notifying human agents.
- **LLM-Powered Analysis**: Self-healing agent uses LLMs to decode complex error traces into actionable root causes.

## Cross-Cutting Concerns

**Logging:** Pino (standardized across custom services), Loki/Grafana for aggregation.
**Validation:** Zod (middleware request validation).
**Authentication:** Shared secrets (handoff), API Keys (Chatwoot/Dify/Evolution).

---

*Architecture analysis: 2025-01-24*
