# Codebase Structure

**Analysis Date:** 2025-01-24

## Directory Layout

```
chat-services/
├── agents/
│   └── self-healing/    # LLM-powered error analysis agent
├── dify-apps/           # Dify workflow/app exports (YAML)
├── docs/                # Planning and sample documentation
├── infrastructure/
│   └── postgres/        # DB initialization scripts
├── middleware/          # Chatwoot ⇄ Dify adapter (Node.js/TS)
├── observability/       # Grafana, Loki, Prometheus, OTEL configs
├── provisioning/        # Deployment and tenant setup scripts
├── scripts/             # Operational scripts (backup, etc.)
└── docker-compose.yml   # Full stack orchestration
```

## Directory Purposes

**agents/self-healing/:**
- Purpose: Polling Loki for errors and analyzing them with Dify.
- Contains: TypeScript source code, Dockerfile, and package configuration.
- Key files: `agents/self-healing/src/index.ts`.

**middleware/:**
- Purpose: The core logic for routing messages between platforms.
- Contains: Fastify handlers, API clients, and tenant management.
- Key files: `middleware/src/index.ts`, `middleware/src/handlers/chatwoot-webhook.ts`.

**observability/:**
- Purpose: Configuration and provisioning for the observability stack.
- Contains: YAML configs and Grafana dashboard JSONs.
- Key files: `observability/prometheus/prometheus.yml`, `observability/grafana/provisioning/dashboards/chat-services.json`.

**infrastructure/postgres/:**
- Purpose: Database schema setup for all services.
- Key files: `infrastructure/postgres/01-init.sql`.

## Key File Locations

**Entry Points:**
- `middleware/src/index.ts`: Fastify server entry.
- `agents/self-healing/src/index.ts`: Agent polling loop entry.

**Configuration:**
- `.env.example`: Template for all environment variables.
- `middleware/src/config.ts`: Configuration parsing and tenant resolution.

**Core Logic:**
- `middleware/src/chatwoot.ts`: Chatwoot API wrapper.
- `middleware/src/dify.ts`: Dify API wrapper.

**Testing:**
- Not detected (No dedicated `test/` or `*.test.ts` files found in the current tree).

## Naming Conventions

**Files:**
- TypeScript: Kebab-case (e.g., `chatwoot-webhook.ts`).
- Config: Snake-case or kebab-case (e.g., `01-init.sql`, `config.yaml`).

**Directories:**
- Kebab-case (e.g., `self-healing`, `dify-apps`).

## Where to Add New Code

**New Feature (Chat logic):**
- Primary code: `middleware/src/handlers/` for new endpoints or logic branches.
- Client logic: `middleware/src/` if it involves a new external service.

**New Agent/Worker:**
- Implementation: Create a new directory under `agents/` with its own `Dockerfile` and `package.json`.

**New Dashboard/Metric:**
- Grafana: Add JSON to `observability/grafana/provisioning/dashboards/`.
- Prometheus: Update `observability/prometheus/prometheus.yml`.

## Special Directories

**dify-apps/:**
- Purpose: Holds the source-of-truth for Dify application configurations.
- Generated: No (manually exported from Dify UI).
- Committed: Yes.

**infrastructure/postgres/:**
- Purpose: Auto-executed by the Postgres container on first run to create databases and extensions.
- Committed: Yes.

---

*Structure analysis: 2025-01-24*
