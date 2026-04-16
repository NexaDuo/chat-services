# Phase 5: Core Service Deployment - Pattern Map

**Mapped:** 2026-04-16
**Files analyzed:** 9 new/modified files
**Analogs found:** 9 / 9

---

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `infrastructure/terraform/envs/production/main.tf` (modify) | config / IaC | request-response | `infrastructure/terraform/envs/production/main.tf` (existing) | exact — extend in place |
| `infrastructure/terraform/envs/production/variables.tf` (modify) | config / IaC | — | `infrastructure/terraform/envs/production/variables.tf` (existing) | exact — add vars |
| `infrastructure/terraform/envs/production/terraform.tfvars.example` (modify) | config | — | `infrastructure/terraform/envs/production/terraform.tfvars.example` (existing) | exact — add keys |
| `deploy/docker-compose.shared.yml` (modify) | config | — | `deploy/docker-compose.shared.yml` (existing) | exact — network block only |
| `deploy/docker-compose.chatwoot.yml` (modify) | config | — | `deploy/docker-compose.chatwoot.yml` (existing) | exact — network block only |
| `deploy/docker-compose.dify.yml` (modify) | config | — | `deploy/docker-compose.dify.yml` (existing) | exact — network block only |
| `deploy/docker-compose.nexaduo.yml` (modify) | config | — | `deploy/docker-compose.nexaduo.yml` (existing) | exact — add prometheus service + network block |
| `scripts/health-check-all.sh` (new) | utility | request-response | `scripts/validate-stack.sh` | role-match — same bash health-probe idiom |
| `scripts/verify-middleware-health.sh` (new) | utility | request-response | `scripts/validate-stack.sh` | role-match |
| `scripts/verify-observability.sh` (new) | utility | request-response | `scripts/validate-stack.sh` | role-match |

---

## Pattern Assignments

### `infrastructure/terraform/envs/production/main.tf` (IaC, extend in place)

**Analog:** `infrastructure/terraform/envs/production/main.tf` (lines 1–57)

The file currently has five `module` blocks and two inline `output` blocks. New `coolify_service`, `coolify_service_envs`, and `null_resource` resources are appended below the existing modules — no new file, no new module directory (Option A per RESEARCH.md).

**Existing module call pattern** (lines 1–12) — copy the block structure, not module internals:
```hcl
module "vm" {
  source = "../../modules/gcp-vm"

  project_id   = var.gcp_project_id
  region       = var.gcp_region
  zone         = var.gcp_zone
  name         = var.app_name
  machine_type = var.machine_type
  disk_size    = var.disk_size
  ssh_user     = var.ssh_user
  ssh_key      = var.ssh_key
}
```

**Coolify provider already wired** in `providers.tf` (lines 27–31):
```hcl
provider "coolify" {
  endpoint = "http://${module.vm.public_ip}:8000/api/v1"
  token    = var.coolify_api_token
}
```
The provider depends on `module.vm.public_ip`, so all `coolify_*` resources implicitly depend on the VM being ready.

**Existing coolify_application pattern** (`infrastructure/terraform/modules/coolify-management/main.tf` lines 26–69) — shows `coolify_project`, `data.coolify_server`, and inline env vars. Phase 5 replaces `coolify_application` with `coolify_service` (correct resource for Docker Compose stacks per RESEARCH.md p.627):
```hcl
# existing (reference only — coolify_application is for single-image apps)
resource "coolify_application" "cloudflared" {
  name         = "cloudflared-tunnel"
  project_uuid = coolify_project.main.uuid
  server_uuid  = data.coolify_server.main.uuid
  source_type  = "docker_compose"
  docker_compose_raw = <<-EOT
    ...
  EOT
  variables = [{ name = "TUNNEL_TOKEN", value = var.tunnel_token }]
}
```

**New resource pattern to use** (`coolify_service` + `coolify_service_envs`, from RESEARCH.md Pattern 1):
```hcl
# Step 0: pre-create shared Docker network on the host before any stack deploys
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

# Step 1: shared stack (postgres + redis) — foundation; no app-level depends_on
resource "coolify_service" "shared" {
  name             = "nexaduo-shared"
  server_uuid      = data.coolify_servers.main.servers[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false
  compose          = file("${path.root}/../../../deploy/docker-compose.shared.yml")
  depends_on       = [null_resource.create_shared_network]
}

resource "coolify_service_envs" "shared" {
  uuid = coolify_service.shared.uuid
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
    key   = "POSTGRES_USER"
    value = var.postgres_user
  }
  env {
    key   = "TZ"
    value = "America/Sao_Paulo"
  }
}

# Step 2: chatwoot stack — depends on shared (postgres/redis must exist first)
resource "coolify_service" "chatwoot" {
  name             = "nexaduo-chatwoot"
  server_uuid      = data.coolify_servers.main.servers[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false
  compose          = file("${path.root}/../../../deploy/docker-compose.chatwoot.yml")
  depends_on       = [coolify_service.shared]
}

# Step 3: dify stack — depends on shared
resource "coolify_service" "dify" {
  name             = "nexaduo-dify"
  server_uuid      = data.coolify_servers.main.servers[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false
  compose          = file("${path.root}/../../../deploy/docker-compose.dify.yml")
  depends_on       = [coolify_service.shared]
}

# Step 4: nexaduo stack (middleware + evolution + observability) — depends on chatwoot + dify
resource "coolify_service" "nexaduo" {
  name             = "nexaduo-nexaduo"
  server_uuid      = data.coolify_servers.main.servers[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false
  compose          = file("${path.root}/../../../deploy/docker-compose.nexaduo.yml")
  depends_on       = [coolify_service.chatwoot, coolify_service.dify]
}
```

**Post-deploy health probe pattern** (RESEARCH.md Pattern 4):
```hcl
resource "null_resource" "verify_chatwoot" {
  depends_on = [coolify_service.chatwoot]
  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    host        = module.vm.public_ip
  }
  provisioner "remote-exec" {
    inline = [
      "timeout 120 bash -c 'until curl -sf http://localhost:3000/ > /dev/null; do sleep 5; done'",
      "echo 'Chatwoot OK'"
    ]
  }
}
```

**Data source pattern** (RESEARCH.md Example 1, replaces legacy `coolify_server` used in coolify-management module — note: production providers.tf already has coolify provider configured):
```hcl
data "coolify_servers" "main" {}  # returns all servers; use [0] for single-server setups

resource "coolify_project" "main" {
  name = "NexaDuo Chat Services"
}
```

---

### `infrastructure/terraform/envs/production/variables.tf` (IaC, extend in place)

**Analog:** `infrastructure/terraform/envs/production/variables.tf` (lines 1–76)

**Existing variable declaration pattern** (lines 1–8, 43–48) — use this structure for every new secret:
```hcl
# Non-sensitive string with default
variable "postgres_user" {
  type    = string
  default = "postgres"
}

# Sensitive string — no default, marked sensitive
variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "coolify_api_token" {
  type      = string
  sensitive = true
}
```

**Variables to add** (derived from `.env.example` mapped to Terraform vars per D-03):
All secrets from `.env.example` that are injected via `coolify_service_envs` require a matching `variable` block here. Key additions:
- `postgres_password` (sensitive)
- `postgres_user` (default: "postgres")
- `redis_password` (sensitive)
- `chatwoot_secret_key_base` (sensitive)
- `chatwoot_frontend_url`
- `dify_secret_key` (sensitive)
- `dify_console_api_url`
- `dify_app_api_url`
- `dify_sandbox_api_key` (sensitive)
- `dify_plugin_daemon_key` (sensitive)
- `dify_plugin_dify_inner_api_key` (sensitive)
- `evolution_authentication_api_key` (sensitive)
- `chatwoot_api_token` (sensitive)
- `handoff_shared_secret` (sensitive)
- `grafana_admin_password` (sensitive)
- `ssh_private_key_path` (used by null_resource connection blocks)

---

### `infrastructure/terraform/envs/production/terraform.tfvars.example` (config, extend)

**Analog:** `infrastructure/terraform/envs/production/terraform.tfvars.example` (lines 1–6)

**Existing format** (all lines) — copy this placeholder pattern exactly:
```hcl
gcp_project_id        = "your-gcp-project-id"
gcp_credentials_file  = "/path/to/your/service-account-key.json"
ssh_key               = "ssh-rsa AAAAB3..."
cloudflare_api_token  = "your-api-token"
cloudflare_zone_id    = "your-zone-id"
cloudflare_account_id = "your-account-id"
```

New entries to append follow the same `key = "placeholder"` style with descriptive placeholders showing generation command where applicable:
```hcl
# Coolify service secrets
postgres_password           = "generate: openssl rand -hex 32"
redis_password              = "generate: openssl rand -hex 32"
chatwoot_secret_key_base    = "generate: openssl rand -hex 64"
dify_secret_key             = "generate: openssl rand -hex 32"
handoff_shared_secret       = "generate: openssl rand -hex 32"
evolution_authentication_api_key = "your-evolution-api-key"
chatwoot_api_token          = "your-chatwoot-api-token"
grafana_admin_password      = "generate: openssl rand -hex 16"
ssh_private_key_path        = "~/.ssh/nexaduo-gcp"
```

---

### `deploy/docker-compose.shared.yml` (modify — network block only)

**Analog:** `deploy/docker-compose.shared.yml` lines 53–54 (current network declaration)

**Current pattern** (line 53–54) — this is the only section that changes:
```yaml
networks:
  chat-network:
    name: ${COMPOSE_PROJECT_NAME:-nexaduo}-network
```

**Replace with** (RESEARCH.md Pattern 2 / Critical Finding section):
```yaml
networks:
  chat-network:
    external: true
    name: nexaduo-network
```

All service blocks (`postgres`, `redis`) already declare `networks: - chat-network` — those lines are unchanged.

---

### `deploy/docker-compose.chatwoot.yml` (modify — network block only)

**Analog:** `deploy/docker-compose.chatwoot.yml` lines 93–95

**Same single-change pattern as shared.yml:**
```yaml
# Before (line 93-95)
networks:
  chat-network:
    name: ${COMPOSE_PROJECT_NAME:-nexaduo}-network

# After
networks:
  chat-network:
    external: true
    name: nexaduo-network
```

No other changes. All service network references (`- chat-network`) are correct as-is.

---

### `deploy/docker-compose.dify.yml` (modify — network block only)

**Analog:** `deploy/docker-compose.dify.yml` lines 141–143

**Same single-change pattern:**
```yaml
# Before (lines 141-143)
networks:
  chat-network:
    name: ${COMPOSE_PROJECT_NAME:-nexaduo}-network

# After
networks:
  chat-network:
    external: true
    name: nexaduo-network
```

---

### `deploy/docker-compose.nexaduo.yml` (modify — network block + add prometheus service)

**Analog:** `deploy/docker-compose.nexaduo.yml` (full file for pattern) + `observability/prometheus/prometheus.yml` (for prometheus config path)

**Change 1 — network block** (lines 103–105):
```yaml
# Before
networks:
  chat-network:
    name: ${COMPOSE_PROJECT_NAME:-nexaduo}-network

# After
networks:
  chat-network:
    external: true
    name: nexaduo-network
```

**Change 2 — add prometheus service** before the `volumes:` block. Model after the `grafana` service in the same file (lines 69–82) for structure consistency:
```yaml
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
```

**Change 3 — add prometheus-data to volumes section** (after `grafana-data:`):
```yaml
volumes:
  evolution-instances:
  loki-data:
  grafana-data:
  prometheus-data:     # add this line
```

The `../observability/prometheus/prometheus.yml` config already scrapes `middleware:4000` and `otel-collector:8889` — no changes needed to that file. Grafana's Prometheus datasource will also need `POSTGRES_USER` and `POSTGRES_PASSWORD` in `coolify_service_envs.nexaduo` to satisfy the Grafana provisioning env-var interpolation (RESEARCH.md Pitfall 3).

---

### `scripts/health-check-all.sh` (new — E2E health check script)

**Analog:** `scripts/validate-stack.sh` (full file, lines 1–66) — exact same bash idiom

**Shebang and safety flags pattern** (lines 1–10):
```bash
#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$(mktemp -d)"
trap 'echo "Logs retained at: $LOG_DIR"' EXIT

step() { echo "==> $*"; }
fail() {
  echo "FAIL: $1" >&2
  if [[ -n "${2:-}" && -f "$2" ]]; then
    echo "---- last 60 lines of $2 ----" >&2
    tail -60 "$2" >&2
  fi
  exit 1
}
```

**HTTP polling pattern** (lines 42–47 of validate-stack.sh) — reuse for all endpoints:
```bash
step "waiting for Dify API (up to 3 min)"
for i in $(seq 1 36); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5001/console/api/setup || true)
  [[ "$code" == "200" ]] && break
  sleep 5
done
[[ "$code" == "200" ]] || fail "Dify API never returned 200 (last=$code)"
```

**Docker health status pattern** (lines 34–39 of validate-stack.sh) — for Chatwoot and postgres:
```bash
step "waiting for chatwoot-rails to be healthy (up to 5 min)"
for i in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' nexaduo-chatwoot-rails 2>/dev/null || echo "missing")
  [[ "$status" == "healthy" ]] && break
  sleep 5
done
[[ "$status" == "healthy" ]] || fail "chatwoot-rails never became healthy (status=$status)"
```

**Restart/unhealthy container check pattern** (lines 62–64 of validate-stack.sh):
```bash
bad=$(docker ps --filter "name=nexaduo-" --format '{{.Names}} {{.Status}}' | grep -Ei 'restart|unhealthy' || true)
[[ -z "$bad" ]] || { echo "$bad" >&2; fail "unhealthy/restarting containers detected"; }
```

The new `health-check-all.sh` combines checks for all four stacks in a single script. It does NOT run `docker compose down -v` (validate-stack.sh does a destructive fresh-start; health-check-all.sh is non-destructive — assert running state only). Endpoints to check:
- Postgres: `docker inspect -f '{{.State.Health.Status}}' nexaduo-postgres`
- Redis: `docker inspect -f '{{.State.Health.Status}}' nexaduo-redis`
- Chatwoot: `curl -sf http://localhost:3000/`
- Dify API: `curl -sf http://localhost:5001/console/api/setup`
- Evolution API: `curl -sf http://localhost:8080/`
- Middleware: `curl -sf http://localhost:4000/health`
- Grafana: `curl -sf http://localhost:3002/login`
- Prometheus: `curl -sf http://localhost:9090/-/healthy`

---

### `scripts/verify-middleware-health.sh` (new)

**Analog:** `scripts/validate-stack.sh` lines 1–10, 42–47 — focused HTTP probe variant

**Pattern to copy** (HTTP polling + exit code check from validate-stack.sh):
```bash
#!/usr/bin/env bash
set -euo pipefail

step() { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

MIDDLEWARE_URL="${MIDDLEWARE_URL:-http://localhost:4000}"

step "Checking middleware /health"
code=$(curl -s -o /dev/null -w '%{http_code}' "${MIDDLEWARE_URL}/health" || true)
[[ "$code" == "200" ]] || fail "Middleware /health returned $code (expected 200)"

step "Checking middleware /config (auth required)"
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${HANDOFF_SHARED_SECRET}" \
  "${MIDDLEWARE_URL}/config" || true)
[[ "$code" == "200" ]] || fail "Middleware /config returned $code (expected 200)"

echo "OK middleware healthy"
```

Note: `HANDOFF_SHARED_SECRET` must be available in the environment (sourced from `.env` or passed explicitly), following the pattern in `backup.sh` lines 18–23 of sourcing `.env` when present.

---

### `scripts/verify-observability.sh` (new)

**Analog:** `scripts/validate-stack.sh` lines 42–47 (HTTP probe pattern) + `scripts/backup.sh` lines 18–23 (env sourcing pattern)

**Pattern to copy:**
```bash
#!/usr/bin/env bash
set -euo pipefail

step() { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3002}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"

# Grafana
step "Checking Grafana login page"
code=$(curl -s -o /dev/null -w '%{http_code}' "${GRAFANA_URL}/login" || true)
[[ "$code" == "200" ]] || fail "Grafana returned $code"

# Prometheus
step "Checking Prometheus readiness"
code=$(curl -s -o /dev/null -w '%{http_code}' "${PROMETHEUS_URL}/-/healthy" || true)
[[ "$code" == "200" ]] || fail "Prometheus returned $code"

# Loki (readiness endpoint)
step "Checking Loki readiness"
code=$(curl -s -o /dev/null -w '%{http_code}' "${LOKI_URL}/ready" || true)
[[ "$code" == "200" ]] || fail "Loki returned $code"

echo "OK all observability services healthy"
```

---

## Shared Patterns

### Terraform Variable Declaration (sensitive)
**Source:** `infrastructure/terraform/envs/production/variables.tf` lines 43–48
**Apply to:** All new `variables.tf` additions for secrets

```hcl
variable "coolify_api_token" {
  type      = string
  sensitive = true
}
```

### Terraform Module Call Structure
**Source:** `infrastructure/terraform/envs/production/main.tf` lines 1–12
**Apply to:** `data.coolify_servers`, `coolify_project`, `coolify_service` blocks — preserve the vertical alignment style (all `=` signs aligned)

### null_resource SSH Connection Block
**Source:** RESEARCH.md Pattern 2 — no exact prior codebase example, but `infrastructure/terraform/modules/gcp-vm/main.tf` line 117 uses `metadata_startup_script = file(...)` as the closest existing SSH-provisioner analog
**Apply to:** `null_resource.create_shared_network`, `null_resource.verify_*` resources

```hcl
connection {
  type        = "ssh"
  user        = var.ssh_user
  private_key = file(var.ssh_private_key_path)
  host        = module.vm.public_ip
}
```

### Bash Script Safety Header
**Source:** `scripts/validate-stack.sh` lines 1–10 and `scripts/backup.sh` lines 1–11
**Apply to:** All new `.sh` scripts — every script begins with `set -euo pipefail` and defines `step()` / `fail()` helpers

```bash
#!/usr/bin/env bash
set -euo pipefail
step() { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit 1; }
```

### compose = file(...) — Never Inline Compose in HCL
**Source:** RESEARCH.md Anti-Patterns section
**Apply to:** All `coolify_service` resources — compose content stays in `deploy/docker-compose.*.yml`

```hcl
compose = file("${path.root}/../../../deploy/docker-compose.shared.yml")
```

### instant_deploy = false
**Source:** RESEARCH.md Pitfall 2 and Pattern 1
**Apply to:** All `coolify_service` resources — prevents UUID resolution race with immediately-following `coolify_service_envs`

### Docker Network External Declaration
**Source:** All four `deploy/docker-compose.*.yml` network sections (current form to be replaced)
**Apply to:** All four compose files — identical change in each

```yaml
networks:
  chat-network:
    external: true
    name: nexaduo-network
```

### env_file Preserved
**Source:** `deploy/docker-compose.chatwoot.yml` line 15, `deploy/docker-compose.nexaduo.yml` lines 12, 35
**Apply to:** When modifying compose files — do NOT remove `env_file: ../.env` lines from service definitions. Terraform's `coolify_service_envs` supplements but does not replace runtime env loading.

### is_literal = true for Secrets
**Source:** RESEARCH.md Example 3 (`coolify_service_envs` pattern)
**Apply to:** All `coolify_service_envs` `env` blocks where `value` is a sensitive Terraform variable

```hcl
env {
  key        = "POSTGRES_PASSWORD"
  value      = var.postgres_password
  is_literal = true
}
```

---

## No Analog Found

All files have sufficient analog coverage. The `null_resource` + `remote-exec` SSH provisioner pattern (used for `create_shared_network` and health probes) has no prior use in this codebase but is a standard Terraform pattern documented in RESEARCH.md with HIGH confidence from the Terraform Registry.

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| — | — | — | All files have analogs |

---

## Critical Constraints for Planner

1. **Volume name continuity** — RESEARCH.md Runtime State Inventory notes existing PoC Docker volumes use `nexaduo_` prefix. Planner must explicitly decide: preserve PoC volumes or accept fresh state. Include a decision step in PLAN.md before `terraform apply`.

2. **Build context for middleware and self-healing-agent** — Both services in `docker-compose.nexaduo.yml` use `build: context: ../middleware` and `build: context: ../agents/self-healing`. This is a blocking issue for Coolify `coolify_service` deploy. Planner must include a pre-build step (docker build + push to registry and update compose to use image tag) OR verify Coolify resolves build contexts from repo clone. See RESEARCH.md Pitfalls 5 and 6, Assumption A2.

3. **HANDOFF_SHARED_SECRET cleanup** — `.env.example` contains a real secret value (`28369644b8f8d9a3dcfe617686c0e757`). Include a 1-task step to replace with placeholder `${secret_hex_32}` before Phase 5 commit. Noted in RESEARCH.md Open Question 4.

4. **Terraform apply environment** — Terraform binary is not on local dev machine. Planner must document that `terraform apply` runs from the GCP VM or CI pipeline, not local shell.

---

## Metadata

**Analog search scope:** `infrastructure/terraform/`, `deploy/`, `scripts/`, `observability/`
**Files scanned:** 18
**Pattern extraction date:** 2026-04-16
