# Codebase Structure

**Analysis Date:** 2026-04-14

## Directory Layout

```
chat-services/
├── .planning/
│   ├── phases/          # Project execution phases (current & past)
│   │   ├── 01-foundation/
│   │   ├── 02-management-and-edge-connectivity/
│   │   ├── 04-automated-provisioning/    # (Empty/Pending)
│   │   └── 05-core-service-deployment/   # (Active/Completed)
│   ├── codebase/        # Analysis and mapping documents
│   ├── research/        # Initial technology research
│   ├── PROJECT.md       # Core project definition
│   ├── ROADMAP.md       # High-level timeline and goals
│   ├── STATE.md         # Current execution state
│   └── REQUIREMENTS.md  # Detailed technical requirements
├── agents/
│   └── self-healing/    # LLM-powered error analysis agent
├── automation/          # Initial setup and lifecycle scripts
├── deploy/              # Docker Compose templates for services
├── dify-apps/           # Dify workflow/app exports (YAML)
├── docs/                # Planning and sample documentation
├── infrastructure/
│   ├── postgres/        # DB initialization scripts
│   └── terraform/       # Infrastructure as Code (GCP, Cloudflare)
├── middleware/          # Chatwoot ⇄ Dify adapter (Node.js/TS)
├── observability/       # Grafana, Loki, Prometheus, OTEL configs
├── provisioning/        # Tenant setup scripts
├── scripts/             # Operational scripts (backup, validation)
└── validation/          # Audit and validation scripts
```

## Directory Purposes

**[.planning/phases/]:**
- Purpose: Historical and active plan records.
- Note: Phase numbering is currently inconsistent between the file system and roadmap.
- Key files: `.planning/phases/05-core-service-deployment/04-PLAN.md` (Wait, yes, the numbering is shifted).

**.planning/codebase/:**
- Purpose: Source-of-truth for the current codebase mapping.
- Contains: `ARCHITECTURE.md`, `STRUCTURE.md`, `STACK.md`, `INTEGRATIONS.md`, `CONCERNS.md`, `CONVENTIONS.md`, `TESTING.md`.

**infrastructure/terraform/:**
- Purpose: Manages all cloud and edge infrastructure.
- Contains: `envs/production` for the live environment and `modules/` for reusable GCP/Cloudflare components.

**middleware/:**
- Purpose: The core logic for routing messages between platforms.
- Contains: Fastify handlers, API clients, and tenant management.
- Key files: `middleware/src/index.ts`, `middleware/src/handlers/chatwoot-webhook.ts`.

**deploy/:**
- Purpose: Modular Docker Compose files used by Coolify to orchestrate services.
- Key files: `docker-compose.chatwoot.yml`, `docker-compose.dify.yml`, `docker-compose.shared.yml`.

## Key File Locations

**Entry Points:**
- `middleware/src/index.ts`: Fastify server entry.
- `agents/self-healing/src/index.ts`: Agent polling loop entry.

**Configuration:**
- `.planning/ROADMAP.md`: Project roadmap.
- `.planning/STATE.md`: Current execution state.
- `infrastructure/terraform/envs/production/terraform.tfvars`: Infrastructure variables.

**Core Logic:**
- `middleware/src/chatwoot.ts`: Chatwoot API wrapper.
- `middleware/src/dify.ts`: Dify API wrapper.

**Testing:**
- `validation/phase2_audit.sh`: Script for auditing infrastructure state.
- (Note: No standard unit test suites found yet).

## Naming Conventions

**Files:**
- TypeScript: Kebab-case (e.g., `chatwoot-webhook.ts`).
- Terraform: Kebab-case (e.g., `cloudflare-dns`).
- Scripts: Kebab-case or snake_case (e.g., `create-tenant.sh`, `phase2_audit.sh`).

**Directories:**
- Kebab-case (e.g., `self-healing`, `dify-apps`).

## Where to Add New Code

**New Phase/Plan:**
- Location: `.planning/phases/` (Follow naming convention: `[XX]-[phase-name]/[XX]-[YY]-PLAN.md`).

**New Infrastructure Resource:**
- Location: `infrastructure/terraform/modules/` or `infrastructure/terraform/envs/production/`.

**New Feature (Chat logic):**
- Implementation: `middleware/src/handlers/` or `middleware/src/` for core logic.

**New Deployment Service:**
- Location: `deploy/` for the compose file, then referenced in Terraform.

## Special Directories

**dify-apps/:**
- Purpose: Holds the source-of-truth for Dify application configurations.
- Committed: Yes.

**infrastructure/terraform/:**
- Purpose: Primary infrastructure definition.
- Committed: Yes.

---

*Structure analysis: 2026-04-14*
