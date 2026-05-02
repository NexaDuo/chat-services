# Architecture

**Analysis Date:** 2026-04-14

## Pattern Overview

**Overall:** Hexagonal/Adapter Architecture with Portless Ingress.

The system acts as a multi-tenant adapter between customer service (Chatwoot) and AI (Dify). It leverages "Portless Origin" security via Cloudflare Tunnels and follows a path-based multi-tenancy model.

**Key Characteristics:**
- **Portless Ingress:** No public ports are open on the origin; all traffic flows through an encrypted Cloudflare Tunnel.
- **Path-based Multi-tenancy:** Routing to tenants is handled via subpaths (e.g., `/alpha/`) rather than subdomains.
- **Unified Infrastructure as Code:** GCP, Cloudflare, and application orchestration are all managed via Terraform.

## Layers

**Communication Layer:**
- Purpose: Bridge WhatsApp/Instagram to Chatwoot.
- Location: `Evolution API` (Docker container).
- Used by: Chatwoot.

**Orchestration Layer:**
- Purpose: Central human-bot inbox.
- Location: `Chatwoot` (Docker container).
- Used by: Middleware.

**Adapter Layer (Custom):**
- Purpose: Translates Chatwoot webhooks to Dify API calls and handles tenant-specific logic.
- Location: `middleware/src/`
- Contains: `chatwoot-webhook.ts`, `handoff.ts`, `tenant.ts`.

**Cognitive Layer:**
- Purpose: LLM agentic engine and RAG workflows.
- Location: `Dify` (Docker container).
- Used by: Middleware.

**Infrastructure Layer:**
- Purpose: Underlying hosting and network security.
- Location: GCP (Compute Engine) + Cloudflare (Tunnels/DNS).
- Managed by: Hybrid approach (Terraform + Bash).
- **Deployment Process:** 3-step isolated flow:
    1. **Foundation Layer (Terraform):** Provisions VM, VPC, and Cloudflare Tunnel.
    2. **Bootstrap Step (Script):** Installs Coolify, generates API tokens, and populates GCP Secret Manager.
    3. **Application Stack (Bash/Docker):** Deploys services directly via SCP/SSH using `scripts/deploy-tenant-direct.sh`.
- **Rationale:** Separation prevents Terraform provider initialization timeouts and avoids the brittle Coolify Terraform provider for complex multi-container stacks.

## Data Flow

**Standard Chat Flow:**
1. User (WhatsApp) → Evolution API → Chatwoot.
2. Chatwoot → Webhook (via Cloudflare Tunnel) → `middleware/src/handlers/chatwoot-webhook.ts`.
3. Middleware → Dify API (per-tenant API key) → LLM Output.
4. Dify Output → Middleware → Chatwoot API → Evolution API → User.

**Routing Logic:**
1. Incoming request to `chat.nexaduo.com/{tenant}/`.
2. Cloudflare Worker (Planned) / Middleware (Current) extracts `{tenant}`.
3. Middleware queries Postgres `tenants` table to find the corresponding `DIFY_API_KEY`.
4. Request is forwarded to the shared Dify instance with the tenant's context.

## Key Abstractions

**Tenant Resolver:**
- Purpose: Maps subpaths to tenant IDs and configurations.
- Examples: `middleware/src/config.ts`, `middleware/src/handlers/tenant.ts`.

**Shared PostgreSQL Backbone:**
- Purpose: Centralized persistence for Chatwoot, Dify, and Middleware.
- Location: `infrastructure/postgres/01-init.sql`.

## Entry Points

**Main Middleware Entry:**
- Location: `middleware/src/index.ts`
- Triggers: Webhooks from Chatwoot or Dify tool calls.

**GCP Infrastructure:**
- Foundation: `infrastructure/terraform/envs/production/foundation/`
- Tenant: `infrastructure/terraform/envs/production/tenant/`
- Triggers: `terraform apply` in respective directories.

## Error Handling

**Strategy:** Fail-soft with persistent analysis.

**Patterns:**
- **Private Note Log:** Middleware posts failures as private notes in Chatwoot for human review.
- **Automated Root Cause:** Self-healing agent analyzes Loki error logs to determine if the failure was transient or systematic.

## Cross-Cutting Concerns

**Logging:** Pino (standardized logs), Loki (aggregation).
**Validation:** Zod (middleware config and payload validation).
**Security:** Cloudflare Tunnel (Inbound), GCP IAP (SSH access), Shared Secret (Internal API).

---

*Architecture analysis: 2026-04-14*
