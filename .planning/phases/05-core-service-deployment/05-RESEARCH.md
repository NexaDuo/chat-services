# Phase 05: Core Service Deployment - Research

**Researched:** 2026-04-16
**Domain:** Coolify IaC (Terraform SierraJC/coolify provider) + Docker Compose multi-stack networking
**Confidence:** HIGH (core IaC patterns verified via official docs), MEDIUM (cross-stack networking — known bug caveats)

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- **D-01:** Usar Terraform via provider `SierraJC/coolify` (v0.10.2) para gerenciar todos os recursos Coolify. Integrado ao IaC existente do projeto (não scripts ad-hoc nem Coolify UI manual).
- **D-02:** Um stack Coolify por serviço — Chatwoot, Dify e Middleware/Evolution API como stacks separados. Isolamento de ciclo de vida: reiniciar um serviço não afeta os outros.
- **D-03:** Secrets gerenciados via Terraform variables + `terraform.tfvars` — consistente com o padrão atual do projeto. `terraform.tfvars` nunca commitado.
- **D-04:** Planos cobrem Terraform completo: recursos Coolify para todos os serviços + rede interna Coolify + env vars injetadas via Terraform. Um plano por stack + um plano de verificação E2E.
- **D-05:** Cada plano de stack inclui validação de saúde pós-deploy (health check do serviço no Coolify ou endpoint de status).

### Compose Sources (definição canônica dos serviços)
- `deploy/docker-compose.shared.yml` — Postgres 16+pgvector, Redis 7
- `deploy/docker-compose.chatwoot.yml` — Chatwoot app + Sidekiq workers
- `deploy/docker-compose.dify.yml` — Dify API, worker, web, sandbox, plugin-daemon, ssrf-proxy
- `deploy/docker-compose.nexaduo.yml` — Middleware bridge + Evolution API + Observability (Loki, Promtail, Grafana)

### Claude's Discretion

- Ordem exata dos recursos Terraform (depends_on entre stacks)
- Nome dos recursos Coolify e network interna
- Detalhes do health check por serviço (endpoint, intervalo)
- Estrutura de módulos Terraform para os recursos Coolify
- Configuração do Middleware bridge, escopo da Observabilidade e critérios de verificação E2E

### Deferred Ideas (OUT OF SCOPE)

- GCP Secret Manager para secrets (continua deferred da Phase 1)
- Docker resource limits por container (a critério do planner, mas não discutido)
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| DEPLOY-01 | Orchestrate Chatwoot, Dify, and Evolution API using Coolify/Docker Compose | Verified: `coolify_service` resource with `compose` field maps each `deploy/*.yml` to a Coolify stack. |
| DEPLOY-02 | Configure Chatwoot and Dify for path-based multi-tenancy via Cloudflare Workers | Existing: Chatwoot `FRONTEND_URL` and Dify `CONSOLE_API_URL` / `APP_API_URL` env vars control public URLs. Cloudflare Worker (Phase 3, complete) handles path routing. Terraform injects correct values. |
| DEPLOY-03 | Deploy the Middleware bridge to handle Chatwoot-Dify communication | Middleware is part of `docker-compose.nexaduo.yml`. Deployed in same Coolify stack as Evolution API. |
| DEPLOY-04 | Deploy Observability stack (Prometheus/Grafana) within the same environment | Grafana + Loki + Promtail are in `docker-compose.nexaduo.yml`. Prometheus is absent from compose but referenced in `observability/prometheus/prometheus.yml`. Planner must decide: add Prometheus container to nexaduo stack, or keep as Claude's discretion. |
</phase_requirements>

---

## Summary

Phase 5 formalizes a PoC that is already manually running. The core task is writing Terraform HCL that creates Coolify `coolify_service` resources pointing to the existing `deploy/docker-compose.*.yml` files, injecting secrets via `coolify_service_envs`, and verifying service health post-deploy.

The most critical architectural challenge is **cross-stack networking**. Each `coolify_service` deploys to its own isolated Docker network by default. All four compose files share the same `chat-network` name — but in Coolify's multi-stack model, this network does NOT span stacks automatically. The "Connect to Predefined Network" UI feature has a known open bug (Issue #5597, April 2025) that prevents it from working with Docker Compose services. The reliable workaround is to declare the shared network as `external: true` in each compose file and ensure the network is pre-created on the host, or — simpler for this project — keep all services in a single `coolify_service` resource (one large compose). Decision D-02 mandates separate stacks, so the planner must use the external network approach and address the naming conflict.

The existing `coolify-management` module already demonstrates the Terraform pattern for Coolify resources. The existing `infrastructure/terraform/envs/production/providers.tf` already configures the `SierraJC/coolify` provider at v0.10.2 with correct endpoint and token.

**Primary recommendation:** Create one `coolify_service` resource per stack group (shared, chatwoot, dify, nexaduo) using `compose = file(...)` to reference the deploy compose files, inject secrets via `coolify_service_envs`, and pre-create a shared Docker network named `nexaduo-network` on the server using a Terraform `null_resource` + `remote-exec` provisioner (or a Coolify Terraform resource if one exists). The E2E verification plan uses the existing `scripts/validate-stack.sh` and `scripts/verify-tenant.ts` as the test harness.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Postgres + Redis (shared infra) | Coolify Stack: shared | — | Stateful foundation; must start before all app stacks |
| Chatwoot app + Sidekiq | Coolify Stack: chatwoot | Cloudflare Worker (edge) | App logic; edge handles path routing (Phase 3 complete) |
| Dify API + worker + web + sandbox | Coolify Stack: dify | — | Agentic engine; self-contained |
| Middleware bridge + Evolution API | Coolify Stack: nexaduo | — | Adapter tier; talks to Chatwoot and Dify via internal network |
| Observability (Grafana, Loki, Promtail) | Coolify Stack: nexaduo | — | Co-deployed in nexaduo stack per existing compose |
| Prometheus scraping | Coolify Stack: nexaduo | — | prometheus.yml exists; Prometheus container must be added to nexaduo compose [ASSUMED] |
| Cross-stack network | Docker host | Terraform provisioner | Network must pre-exist before stacks deploy |
| Secret injection | Terraform variables | coolify_service_envs resource | All secrets from .env.example become Terraform vars |

---

## Standard Stack

### Core IaC

| Resource | Version | Purpose | Source |
|----------|---------|---------|--------|
| `SierraJC/coolify` provider | 0.10.2 | Manages Coolify resources via Terraform | [VERIFIED: providers.tf in codebase, registry.terraform.io] |
| `coolify_service` resource | n/a | Deploys a Docker Compose stack in Coolify | [VERIFIED: registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service] |
| `coolify_service_envs` resource | n/a | Injects environment variables into a service | [VERIFIED: registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service_envs] |
| `data.coolify_servers` | n/a | Looks up the Coolify server UUID | [VERIFIED: registry.terraform.io/providers/SierraJC/coolify/latest/docs/data-sources/servers] |
| `coolify_project` | n/a | Creates/references a Coolify project | [VERIFIED: SierraJC/terraform-provider-coolify GitHub] |
| `hashicorp/google` provider | ~> 5.0 | GCS backend + GCP resources | [VERIFIED: providers.tf in codebase] |
| GCS backend | n/a | Remote state in `nexaduo-terraform-state` | [VERIFIED: backend.tf in codebase] |

### Runtime Services (already defined in compose files)

| Service | Image | Port (internal) | Stack |
|---------|-------|-----------------|-------|
| postgres | pgvector/pgvector:pg16 | 5432 | shared |
| redis | redis:7-alpine | 6379 | shared |
| chatwoot-rails | chatwoot/chatwoot:v4.1.0 | 3000 | chatwoot |
| chatwoot-sidekiq | chatwoot/chatwoot:v4.1.0 | — | chatwoot |
| dify-api | langgenius/dify-api:1.13.3 | 5001 | dify |
| dify-worker | langgenius/dify-api:1.13.3 | — | dify |
| dify-web | langgenius/dify-web:1.13.3 | 3001 | dify |
| dify-sandbox | langgenius/dify-sandbox:0.2.14 | 8194 | dify |
| dify-plugin-daemon | langgenius/dify-plugin-daemon:0.5.3-local | 5002 | dify |
| dify-ssrf-proxy | ubuntu/squid:latest | — | dify |
| evolution-api | atendai/evolution-api:v2.1.1 | 8080 | nexaduo |
| middleware | nexaduo/middleware:dev | 4000 | nexaduo |
| loki | grafana/loki:3.2.0 | 3100 | nexaduo |
| promtail | grafana/promtail:3.1.0 | 9080 | nexaduo |
| grafana | grafana/grafana:11.3.0 | 3002 | nexaduo |
| self-healing-agent | nexaduo/self-healing:dev | — | nexaduo |

[VERIFIED: deploy/docker-compose.*.yml in codebase]

---

## Architecture Patterns

### System Architecture Diagram: Terraform → Coolify → Docker

```
terraform apply
      │
      ├── data.coolify_servers.main ──────────────── reads server UUID
      ├── coolify_project.main ───────────────────── creates/refs project
      │
      ├── null_resource.create_shared_network ──────► SSH: docker network create nexaduo-network
      │
      ├── coolify_service.shared ─────────────────── compose: deploy/docker-compose.shared.yml
      │   └── coolify_service_envs.shared ─────────── POSTGRES_PASSWORD, REDIS_PASSWORD, ...
      │
      ├── coolify_service.chatwoot ───────────────── compose: deploy/docker-compose.chatwoot.yml
      │   └── coolify_service_envs.chatwoot ─────── CHATWOOT_SECRET_KEY_BASE, CHATWOOT_FRONTEND_URL, ...
      │   depends_on: [coolify_service.shared]
      │
      ├── coolify_service.dify ───────────────────── compose: deploy/docker-compose.dify.yml
      │   └── coolify_service_envs.dify ──────────── DIFY_SECRET_KEY, DIFY_CONSOLE_API_URL, ...
      │   depends_on: [coolify_service.shared]
      │
      └── coolify_service.nexaduo ────────────────── compose: deploy/docker-compose.nexaduo.yml
          └── coolify_service_envs.nexaduo ────────── CHATWOOT_API_TOKEN, HANDOFF_SHARED_SECRET, ...
          depends_on: [coolify_service.chatwoot, coolify_service.dify]

On Docker host (Coolify VM):
  nexaduo-network (external, pre-created)
      ├── postgres       ← shared stack
      ├── redis          ← shared stack
      ├── chatwoot-rails ← chatwoot stack
      ├── dify-api       ← dify stack
      ├── middleware     ← nexaduo stack
      └── grafana        ← nexaduo stack
```

### Recommended Terraform Structure

```
infrastructure/terraform/envs/production/
├── backend.tf           # existing — GCS backend
├── providers.tf         # existing — google, cloudflare, coolify
├── variables.tf         # existing + NEW: all .env.example secrets as vars
├── main.tf              # existing (gcp-vm, dns, tunnel) + NEW: coolify service resources
├── outputs.tf           # existing (empty) + optional: service UUIDs
└── terraform.tfvars     # not committed — operator fills from .env.example
```

The planner has two options for organizing the new Coolify resources:

**Option A (recommended, simpler):** Add all four `coolify_service` blocks directly to `main.tf`. The file is currently small (50 lines). This avoids a new module abstraction for four resources.

**Option B (modular):** Create `infrastructure/terraform/modules/coolify-stack/` with a reusable module per stack. Higher abstraction but adds indirection for four one-time deployments.

Given PoC context (formalize existing state, not new build), Option A is appropriate. [ASSUMED]

### Pattern 1: coolify_service with Inline Compose

```hcl
# Source: registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service
resource "coolify_service" "shared" {
  name             = "nexaduo-shared"
  server_uuid      = data.coolify_servers.main.servers[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false

  compose = file("${path.root}/../../../deploy/docker-compose.shared.yml")
}

resource "coolify_service_envs" "shared" {
  uuid = coolify_service.shared.uuid

  env {
    key   = "POSTGRES_USER"
    value = var.postgres_user
  }
  env {
    key        = "POSTGRES_PASSWORD"
    value      = var.postgres_password
    is_literal = true
  }
  env {
    key   = "REDIS_PASSWORD"
    value = var.redis_password
  }
}
```

[VERIFIED: schema from registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service and service_envs]

### Pattern 2: Pre-creating the Shared Docker Network

Because `coolify_service` does not expose a "connect to predefined network" Terraform argument (the UI feature is also buggy — Issue #5597), the shared Docker network must be pre-created via SSH before stacks deploy:

```hcl
# Source: [ASSUMED] — standard Terraform null_resource pattern
resource "null_resource" "create_shared_network" {
  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    host        = module.vm.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "docker network inspect nexaduo-network >/dev/null 2>&1 || docker network create nexaduo-network"
    ]
  }
}
```

Each compose file must then declare the network as external:

```yaml
# deploy/docker-compose.shared.yml (modification required)
networks:
  chat-network:
    external: true
    name: nexaduo-network
```

**CRITICAL:** All four compose files currently declare `chat-network` with `name: ${COMPOSE_PROJECT_NAME:-nexaduo}-network`. In the multi-stack Coolify model, `COMPOSE_PROJECT_NAME` will differ per stack (Coolify sets it to the service UUID), causing the network name to mismatch across stacks. The compose files need updating to use `external: true` with a fixed network name (`nexaduo-network`). [VERIFIED: Coolify docs on cross-stack networking]

### Pattern 3: depends_on Between Coolify Services

Terraform `depends_on` is the right mechanism to sequence stack deployments:

```hcl
resource "coolify_service" "chatwoot" {
  # ...
  depends_on = [coolify_service.shared, null_resource.create_shared_network]
}

resource "coolify_service" "nexaduo" {
  # ...
  depends_on = [coolify_service.chatwoot, coolify_service.dify]
}
```

Note: `depends_on` only controls Terraform apply order, not actual Docker health. The compose files themselves have `depends_on` with health checks for inter-container sequencing within each stack.

### Pattern 4: Post-Deploy Health Verification

For D-05 (health check per stack), use `terraform_data` or `null_resource` with `remote-exec` after each service deploy:

```hcl
# Example: verify Chatwoot is responding
resource "null_resource" "verify_chatwoot" {
  depends_on = [coolify_service.chatwoot]

  connection { ... }

  provisioner "remote-exec" {
    inline = [
      "timeout 120 bash -c 'until curl -sf http://localhost:3000/ > /dev/null; do sleep 5; done'",
      "echo 'Chatwoot OK'"
    ]
  }
}
```

[ASSUMED] — standard Terraform remote-exec health probe pattern.

### Anti-Patterns to Avoid

- **Hardcoding compose content in HCL heredocs:** Use `compose = file(...)` to keep compose files as the single source of truth. Never duplicate compose content in Terraform.
- **Ignoring COMPOSE_PROJECT_NAME collision:** If the network name uses `${COMPOSE_PROJECT_NAME}`, Coolify will override this variable to the stack UUID, breaking cross-stack resolution. Always use a fixed external network name.
- **Using `instant_deploy = true` without health checks:** Immediately applying another resource that depends on service health (e.g., running migrations) will race. Keep `instant_deploy = false` and add explicit health probes.
- **Storing secrets in `terraform.tfvars.example` with real values:** The example file shows placeholder syntax — never put real secrets there. Align with the project's pattern of populating `terraform.tfvars` from `.env.example` locally.
- **Adding `coolify_service_envs` before `coolify_service` is ready:** The `uuid` output of `coolify_service` is only available after the resource is created. Terraform handles this via implicit dependency on `coolify_service.xxx.uuid`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Service-to-service DNS resolution across stacks | Custom DNS entries or IP-based references | External Docker network (`nexaduo-network`) + fixed container names in compose | Docker's internal DNS handles this; IPs change on restart |
| Secret rotation / management | Custom env var updater scripts | `coolify_service_envs` resource (Terraform re-applies update env in Coolify) | Terraform state tracks env vars; re-apply propagates changes |
| DB migration sequencing | Custom wait scripts in Terraform | Compose `depends_on: condition: service_completed_successfully` (already in chatwoot-init, dify-init) | Already implemented in compose files; Coolify respects this |
| Health checks | Custom monitoring scripts in Terraform | Compose `healthcheck` blocks (already defined) + `null_resource` remote-exec probe | Compose healthchecks are already production-ready |
| Grafana datasource setup | Manual Grafana UI clicks | Grafana provisioning YAMLs in `observability/grafana/provisioning/` (already exist) | Auto-provisioned on Grafana container start |

---

## Critical Finding: Cross-Stack Networking

### The Problem

D-02 mandates separate Coolify stacks per service. Coolify by default creates an **isolated network per stack** named after the resource UUID. All four compose files share `chat-network` with name `${COMPOSE_PROJECT_NAME:-nexaduo}-network` — but Coolify overrides `COMPOSE_PROJECT_NAME` to the stack UUID, so each stack creates a different network, and containers in stack A cannot resolve containers in stack B.

### The Workaround (Required)

1. **Pre-create a shared external Docker network** on the VM (e.g., `nexaduo-network`) via `null_resource` + `remote-exec`.
2. **Modify all four compose files** to declare `chat-network` as external, pointing to `nexaduo-network`:
   ```yaml
   networks:
     chat-network:
       external: true
       name: nexaduo-network
   ```
3. All containers across all stacks will then join the same network and resolve each other by container name (e.g., `postgres`, `redis`, `chatwoot-rails`, `dify-api`).

[CITED: coolify.io/docs/knowledge-base/docker/compose — "each compose stack is deployed to a separate network, with the name of your resource uuid"]
[VERIFIED: GitHub Issue #5597 — "Connect to predefined network doesn't work with services or docker based deploys" (open as of April 2025)]

### Impact on Plans

- **Plan 05-01 (shared stack):** Modify `deploy/docker-compose.shared.yml` to use external network.
- **Plan 05-02 (chatwoot stack):** Modify `deploy/docker-compose.chatwoot.yml` similarly.
- **Plan 05-03 (dify stack):** Modify `deploy/docker-compose.dify.yml` similarly.
- **Plan 05-04 (nexaduo stack):** Modify `deploy/docker-compose.nexaduo.yml` similarly.
- **All plans:** `null_resource.create_shared_network` must run before any `coolify_service` resource.

---

## Common Pitfalls

### Pitfall 1: COMPOSE_PROJECT_NAME Override by Coolify

**What goes wrong:** Coolify sets `COMPOSE_PROJECT_NAME` to the stack's UUID internally. The network name `${COMPOSE_PROJECT_NAME:-nexaduo}-network` becomes `<uuid>-network`, making cross-stack DNS fail silently.

**Why it happens:** Coolify isolates stacks by overriding the compose project name.

**How to avoid:** Use `external: true` network with hardcoded name `nexaduo-network` in all compose files.

**Warning signs:** `getaddrinfo ENOTFOUND postgres` errors in middleware logs; `could not connect to server` in Chatwoot.

### Pitfall 2: coolify_service_envs Applied Before Service is Provisioned

**What goes wrong:** If `instant_deploy = true` is combined with an immediately-following `coolify_service_envs`, the UUID may not be resolved yet, causing a Terraform apply failure.

**Why it happens:** `instant_deploy` triggers Coolify to immediately start the stack before Terraform has finished its apply cycle.

**How to avoid:** Keep `instant_deploy = false`; apply envs as a separate Terraform resource; use explicit `depends_on`.

**Warning signs:** `Error: uuid is required` during Terraform apply.

### Pitfall 3: Grafana Datasource Password Interpolation

**What goes wrong:** `observability/grafana/provisioning/datasources/postgres.yml` uses `${POSTGRES_PASSWORD}` — this is Grafana's env var interpolation syntax, not Docker Compose syntax. The Grafana container must have `POSTGRES_PASSWORD` and `POSTGRES_USER` set as environment variables at runtime.

**Why it happens:** Grafana provisioning files support env var substitution, but the env vars must be passed to the Grafana container explicitly.

**How to avoid:** Ensure `GF_SECURITY_ADMIN_PASSWORD`, `POSTGRES_USER`, and `POSTGRES_PASSWORD` are in the `coolify_service_envs.nexaduo` block.

**Warning signs:** Grafana "Self-Healing-DB-V2" datasource shows "Data source connection failed."

### Pitfall 4: Prometheus Container Missing from Compose

**What goes wrong:** `observability/prometheus/prometheus.yml` exists and is referenced in `prometheus.yml`, but **no `prometheus` service** is defined in any of the four compose files. Grafana's Prometheus datasource will fail without a running Prometheus.

**Why it happens:** The PoC was manually completed, and the Prometheus container may have been run separately or omitted.

**How to avoid:** Add a `prometheus` service to `deploy/docker-compose.nexaduo.yml` that mounts `observability/prometheus/prometheus.yml`.

**Warning signs:** Grafana shows "Prometheus datasource is not working: Bad Gateway."

### Pitfall 5: Middleware Image Build in Coolify

**What goes wrong:** `docker-compose.nexaduo.yml` defines `middleware` with `build: context: ../middleware`. Coolify's `coolify_service` resource with `compose = file(...)` requires either a pre-built image or access to the build context path from Coolify's perspective. If Coolify cannot resolve the relative build path, the deploy fails.

**Why it happens:** `compose = file(...)` passes the raw compose content to Coolify; relative paths like `../middleware` are resolved relative to Coolify's working directory, not the Terraform workspace.

**How to avoid:** Either (a) pre-build and push `nexaduo/middleware:prod` to a registry and update the compose to use the image tag, or (b) verify that Coolify resolves build contexts relative to the repo root when cloned. Option (a) is more reliable. [ASSUMED]

**Warning signs:** Coolify deploy logs: `COPY failed: file not found` or `build path does not exist`.

### Pitfall 6: self-healing-agent Image Build Same Issue

**What goes wrong:** Same as Pitfall 5 — `self-healing-agent` uses `build: context: ../agents/self-healing`. Needs pre-built image or alternative approach.

**How to avoid:** Same resolution as Pitfall 5 — pre-build image or verify Coolify build context handling.

---

## Code Examples

### Example 1: data source for server + project

```hcl
# Source: registry.terraform.io/providers/SierraJC/coolify/latest/docs/data-sources/servers
data "coolify_servers" "all" {
  filter {
    name   = "ip"
    values = ["127.0.0.1"]  # Coolify localhost server
  }
}

resource "coolify_project" "nexaduo" {
  name = "NexaDuo Chat Services"
}
```

### Example 2: coolify_service for shared stack

```hcl
# Source: registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service
resource "coolify_service" "shared" {
  name             = "nexaduo-shared"
  server_uuid      = data.coolify_servers.all.servers[0].uuid
  project_uuid     = coolify_project.nexaduo.uuid
  environment_name = "production"
  instant_deploy   = false

  # Compose file is the source of truth
  compose = file("${path.root}/../../../deploy/docker-compose.shared.yml")

  depends_on = [null_resource.create_shared_network]
}
```

### Example 3: coolify_service_envs for shared stack

```hcl
# Source: registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service_envs
resource "coolify_service_envs" "shared" {
  uuid = coolify_service.shared.uuid

  env {
    key   = "COMPOSE_PROJECT_NAME"
    value = "nexaduo"
  }
  env {
    key        = "POSTGRES_PASSWORD"
    value      = var.postgres_password
    is_literal = true
  }
  env {
    key        = "REDIS_PASSWORD"
    value      = var.redis_password
    is_literal = true
  }
  env {
    key   = "TZ"
    value = "America/Sao_Paulo"
  }
}
```

### Example 4: Pre-create shared network

```hcl
# [ASSUMED] standard null_resource pattern
resource "null_resource" "create_shared_network" {
  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    host        = module.vm.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "docker network inspect nexaduo-network >/dev/null 2>&1 || docker network create nexaduo-network"
    ]
  }

  triggers = {
    network_name = "nexaduo-network"
  }
}
```

### Example 5: Modified compose network declaration (all four compose files)

```yaml
# deploy/docker-compose.shared.yml — network section update
networks:
  chat-network:
    external: true
    name: nexaduo-network
```

### Example 6: Adding Prometheus to nexaduo compose

```yaml
# Add to deploy/docker-compose.nexaduo.yml services section
  prometheus:
    image: prom/prometheus:v2.55.0
    container_name: nexaduo-prometheus
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=30d
    volumes:
      - ../observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "9090:9090"
    networks:
      - chat-network

# Add to volumes section
  prometheus-data:
```

[ASSUMED — image version and flags from Prometheus standard practice; verify latest stable version]

---

## Runtime State Inventory

> Phase involves formalizing a PoC that is already manually deployed. The following runtime state exists and must be accounted for.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Postgres databases: chatwoot, dify, dify_plugin, evolution, middleware, self_healing — created by `01-init.sql` | No migration needed — schema is idempotent (`IF NOT EXISTS`). Terraform `coolify_service` deploys will reuse existing data volumes. |
| Live service config | Chatwoot account(s) and admin user created via Playwright automation (`automation/initial-setup.js`). `CHATWOOT_API_TOKEN` may already be set manually. | Capture current `CHATWOOT_API_TOKEN` from running instance before Terraform apply. Add to `terraform.tfvars`. |
| OS-registered state | Docker volumes: postgres-data, redis-data, chatwoot-storage, chatwoot-public, dify-api-storage, dify-plugin-storage, evolution-instances, loki-data, grafana-data. Named under current compose project. | If Coolify's UUID prefix differs from `nexaduo`, volume names will change and data will be lost. Plan must address volume name continuity or accept fresh state. |
| Secrets/env vars | `.env.example` is the canonical template. Actual `.env` is not committed. `HANDOFF_SHARED_SECRET` is hardcoded in `.env.example` (real value present — security risk). | Before committing, replace hardcoded secret in `.env.example` with placeholder. Map all vars to `terraform.tfvars`. |
| Build artifacts | `middleware` and `self-healing-agent` services use local `build:` directives. No pre-built images in a registry. | Either pre-build and push images to a registry (GHCR or Docker Hub), or verify Coolify can execute Docker builds from a cloned repo. This is a blocking issue for Terraform deploy. |

**Critical runtime state item:** Docker volume names created by `docker compose up` use the compose project name as a prefix (e.g., `nexaduo_postgres-data`). If Coolify creates new volumes with a UUID prefix, existing Postgres data is orphaned. The planner must include a step to either: (a) configure Coolify to reuse existing volumes by name, or (b) accept fresh databases and re-run the initial-setup automation.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Docker | All compose deploys | Yes | 29.4.0 | — |
| Terraform | IaC apply | No (on this dev machine) | — | Run from Coolify VM or CI |
| Node.js | Automation scripts, verify-tenant.ts | Yes | 24.14.1 | — |
| npm | JS deps | Yes | 11.11.0 | — |
| Coolify API | Terraform provider | Not verified locally | — | Reachable from GCP VM |
| GCS backend | Terraform state | Not verified locally | — | Requires GCP credentials |
| SSH access to GCP VM | null_resource provisioner | Not verified | — | Required for network pre-creation |

**Missing dependencies with no fallback (on local dev machine):**
- Terraform binary — Terraform apply must run from the GCP VM, a CI pipeline, or a machine with Terraform installed. The planner should note this and either add a Terraform install step or document the assumption.

**Missing dependencies with fallback:**
- None identified with viable local alternatives.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | Bash scripts (existing: `scripts/validate-stack.sh`) + TypeScript (`scripts/verify-tenant.ts`) |
| Config file | none — scripts are self-contained |
| Quick run command | `bash scripts/validate-stack.sh` (requires running Docker stack) |
| Full suite command | `bash scripts/validate-stack.sh && npx ts-node scripts/verify-tenant.ts` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| DEPLOY-01 | All service containers healthy (postgres, redis, chatwoot, dify, evolution) | smoke | `bash scripts/validate-stack.sh` | Yes |
| DEPLOY-02 | Chatwoot accessible at `chat.nexaduo.com/{tenant}/`, assets load | smoke/e2e | manual browser check + `verify-tenant.ts` | Yes |
| DEPLOY-03 | Middleware `/health` returns 200; Chatwoot webhook processed by Middleware | smoke | `curl http://localhost:4000/health` | Wave 0 gap |
| DEPLOY-04 | Grafana returns 200; Prometheus datasource shows data; Loki shows container logs | smoke | `curl http://localhost:3002/login` | Wave 0 gap |

### Sampling Rate

- **Per task commit:** `docker compose ps` — verify no unhealthy containers
- **Per wave merge:** `bash scripts/validate-stack.sh`
- **Phase gate:** Full validate-stack + manual Grafana dashboard check before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `scripts/verify-middleware-health.sh` — covers DEPLOY-03 (middleware `/health` endpoint)
- [ ] `scripts/verify-observability.sh` — covers DEPLOY-04 (Grafana/Prometheus/Loki reachability)
- [ ] Prometheus container definition in `deploy/docker-compose.nexaduo.yml` — prerequisite for DEPLOY-04

*(Existing `validate-stack.sh` covers DEPLOY-01 and partially DEPLOY-02)*

---

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | Not in scope (auth handled by Chatwoot/Dify applications) |
| V3 Session Management | No | Application-level, out of scope |
| V4 Access Control | Yes | Coolify API token and `terraform.tfvars` must not be committed; SSH key for provisioner must have restricted permissions |
| V5 Input Validation | No | No new input paths in IaC |
| V6 Cryptography | Yes | All secrets (Postgres password, Redis password, SECRET_KEY_BASE, etc.) must be generated with `openssl rand -hex 32/64` as documented in `.env.example` |

### Known Threat Patterns for this Stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Coolify API token exposure | Information Disclosure | `sensitive = true` on `coolify_api_token` var; never log in CI |
| Hardcoded `HANDOFF_SHARED_SECRET` in `.env.example` | Tampering | Replace with `${secret_hex_32}` placeholder before any public commit (noted in STATE.md todos) |
| Flat Docker network lateral movement | Elevation of Privilege | Accepted risk per architecture; Cloudflare Tunnel limits external exposure |
| Docker socket mounted in Promtail | Tampering | Promtail mounts `/var/run/docker.sock:ro` (read-only) — acceptable |
| SSH key for `null_resource` provisioner | Spoofing | Use the existing `ssh_key` variable; restrict GCP firewall to known IPs |

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Docker Compose single file | Segmented compose files per stack + root aggregator | Project inception | Enables Coolify lifecycle isolation (D-02) |
| Manual Coolify UI deploys | Terraform `coolify_service` resources | This phase | Reproducible, versionable deploys |
| `coolify_application` resource | `coolify_service` resource | v0.7.0+ of provider | `coolify_service` is the correct resource for Docker Compose stacks; `coolify_application` is for single-image apps |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Option A (flat main.tf) is better than a new module for these four service resources | Architecture Patterns | Low — planner can choose Option B; adds one extra directory |
| A2 | Pre-building middleware and self-healing images is required because Coolify cannot resolve `build: ../middleware` relative paths | Common Pitfalls (Pitfall 5/6) | HIGH — if Coolify can resolve build contexts from repo clone, no pre-build needed. Planner must verify or test. |
| A3 | Adding Prometheus to `docker-compose.nexaduo.yml` is the right place for the missing Prometheus container | Architecture Patterns (Example 6) | Medium — could be a separate stack; nexaduo is already large |
| A4 | Existing Docker volumes from PoC manual deploy may conflict with Coolify-managed volume names | Runtime State Inventory | HIGH — if volumes are incompatible, data loss on redeploy. Planner must explicitly decide: preserve PoC data or fresh start. |
| A5 | `null_resource` + `remote-exec` is available for SSH-based network pre-creation | Architecture Patterns (Pattern 2) | Medium — SSH access from Terraform apply machine must be open. If not, alternative is to pre-create network in provisioning scripts. |
| A6 | Prometheus v2.55.0 is the correct version to add | Code Examples (Example 6) | Low — version can be updated; functionality is standard |

---

## Open Questions

1. **Build context for middleware and self-healing-agent images**
   - What we know: Both services use `build:` directives pointing to sibling directories.
   - What's unclear: Whether Coolify's `coolify_service` with `compose = file(...)` resolves these paths relative to the Coolify server's working directory, and whether the repo is cloned there.
   - Recommendation: Planner should either (a) add a pre-build step (docker build + push to registry) before Terraform apply, or (b) test Coolify's compose build behavior in the PoC environment first.

2. **Docker volume name continuity for PoC data**
   - What we know: PoC was deployed manually; volumes exist with `nexaduo_` prefix. Coolify will likely create volumes with a UUID prefix.
   - What's unclear: Whether the planner wants to preserve existing Postgres data or start fresh.
   - Recommendation: Include a plan step that explicitly documents the choice and, if preserving data, adds a volume rename step.

3. **Terraform apply execution environment**
   - What we know: Terraform binary is not present on the local dev machine.
   - What's unclear: Whether the plan should add a Terraform install step, document a CI pipeline, or assume it runs from the GCP VM.
   - Recommendation: Planner should document the expected apply environment; suggest running from the GCP VM (Terraform available) or GitHub Actions.

4. **HANDOFF_SHARED_SECRET hardcoded in `.env.example`**
   - What we know: `HANDOFF_SHARED_SECRET=28369644b8f8d9a3dcfe617686c0e757` is committed in `.env.example`. STATE.md lists "Harden repo for public GitHub security" as a pending todo.
   - What's unclear: Whether Phase 5 plans should include this cleanup or treat it as out of scope.
   - Recommendation: Include it as a task in the shared plan (30-second fix) to unblock the public GitHub hardening todo.

---

## Sources

### Primary (HIGH confidence)
- `registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service` — `coolify_service` schema, example
- `registry.terraform.io/providers/SierraJC/coolify/latest/docs/resources/service_envs` — `coolify_service_envs` schema, example
- `registry.terraform.io/providers/SierraJC/coolify/latest/docs/data-sources/servers` — `data.coolify_servers` schema
- `github.com/SierraJC/terraform-provider-coolify` — provider feature matrix, available resources
- `coolify.io/docs/knowledge-base/docker/compose` — cross-stack networking behavior, UUID-based network naming
- Codebase: `infrastructure/terraform/envs/production/providers.tf` — provider version 0.10.2, endpoint pattern
- Codebase: `infrastructure/terraform/modules/coolify-management/main.tf` — existing `coolify_application` + `coolify_project` patterns
- Codebase: `deploy/docker-compose.*.yml` — all service definitions (canonical source of truth)
- Codebase: `.env.example` — all secrets and env vars

### Secondary (MEDIUM confidence)
- `github.com/coollabsio/coolify/issues/5597` — "Connect to predefined network doesn't work with services or docker based deploys" (open April 2025)
- `github.com/coollabsio/coolify/discussions/5059` — cross-stack networking patterns and workarounds

### Tertiary (LOW confidence)
- Prometheus addition to nexaduo compose (A3, A6) — based on training knowledge of Prometheus docker image
- `null_resource` SSH provisioner for network pre-creation (A5) — standard Terraform pattern, unverified for this specific Coolify environment

---

## Metadata

**Confidence breakdown:**
- Standard stack (Terraform resources): HIGH — verified via official Terraform Registry docs
- Cross-stack networking: HIGH (problem), MEDIUM (workaround reliability given Issue #5597)
- Architecture patterns: HIGH — based on verified resource schemas and existing codebase patterns
- Pitfalls: HIGH — sourced from verified bugs, codebase inspection, and official Coolify docs
- Build context handling (Pitfall 5/6): LOW — unverified behavior; marked as assumption A2

**Research date:** 2026-04-16
**Valid until:** 2026-05-16 (provider v0.10.2 is stable; Coolify networking bugs are subject to change)
