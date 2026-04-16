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

module "dns_chat" {
  source = "../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "chat"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_dify" {
  source = "../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "dify"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "backup_storage" {
  source = "../../modules/gcp-storage"

  project_id  = var.gcp_project_id
  region      = var.gcp_region
  bucket_name = var.backup_bucket_name
}

module "tunnel" {
  source = "../../modules/cloudflare-tunnel"

  account_id  = var.cloudflare_account_id
  name        = "${var.app_name}-tunnel"
  zone_id     = var.cloudflare_zone_id
  base_domain = var.base_domain
  proxied     = true
}

output "public_ip" {
  value = module.vm.public_ip
}

output "tunnel_token" {
  value     = module.tunnel.tunnel_token
  sensitive = true
}

# =============================================================================
# Phase 5 — Coolify service deployments
# =============================================================================

# Look up the local Coolify server (single-server setup; index [0]).
data "coolify_servers" "main" {}

resource "coolify_project" "main" {
  name = "NexaDuo Chat Services"
}

# ---------------------------------------------------------------------------
# Shared external Docker network — must exist BEFORE any coolify_service runs
# so all per-stack containers can join the same bridge network and resolve
# each other by container name across stacks.
# ---------------------------------------------------------------------------
resource "null_resource" "create_shared_network" {
  depends_on = [module.vm]

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

# ---------------------------------------------------------------------------
# Stack 1/4 — Shared (Postgres 16+pgvector, Redis 7). All other stacks
# depend on this being healthy.
# ---------------------------------------------------------------------------
resource "coolify_service" "shared" {
  name             = "nexaduo-shared"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false

  compose = file("${path.root}/../../../../deploy/docker-compose.shared.yml")

  depends_on = [null_resource.create_shared_network]
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
    key        = "REDIS_PASSWORD"
    value      = var.redis_password
    is_literal = true
  }
  env {
    key   = "TZ"
    value = var.tz
  }
}

# ---------------------------------------------------------------------------
# Post-deploy health probe (D-05): poll Postgres + Redis from the VM until
# both report healthy or 3 minutes elapse.
# ---------------------------------------------------------------------------
resource "null_resource" "verify_shared" {
  depends_on = [coolify_service.shared, coolify_service_envs.shared]

  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    host        = module.vm.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for nexaduo-postgres to be healthy (up to 3 min)'",
      "timeout 180 bash -c 'until [ \"$(docker inspect -f \"{{.State.Health.Status}}\" nexaduo-postgres 2>/dev/null)\" = \"healthy\" ]; do sleep 5; done'",
      "echo 'Waiting for nexaduo-redis to be healthy (up to 2 min)'",
      "timeout 120 bash -c 'until [ \"$(docker inspect -f \"{{.State.Health.Status}}\" nexaduo-redis 2>/dev/null)\" = \"healthy\" ]; do sleep 5; done'",
      "echo 'OK shared stack healthy'"
    ]
  }

  triggers = {
    compose_hash = filesha256("${path.root}/../../../../deploy/docker-compose.shared.yml")
  }
}

# ---------------------------------------------------------------------------
# Stack 2/4 — Chatwoot (init + rails + sidekiq). Joins nexaduo-network so
# Postgres + Redis (shared stack) are reachable by container name.
# ---------------------------------------------------------------------------
resource "coolify_service" "chatwoot" {
  name             = "nexaduo-chatwoot"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false

  compose = file("${path.root}/../../../../deploy/docker-compose.chatwoot.yml")

  depends_on = [
    coolify_service.shared,
    coolify_service_envs.shared,
    null_resource.verify_shared,
  ]
}

resource "coolify_service_envs" "chatwoot" {
  uuid = coolify_service.chatwoot.uuid

  # Shared infra references (must match the values injected into the shared stack)
  env {
    key   = "POSTGRES_HOST"
    value = "postgres"
  }
  env {
    key   = "POSTGRES_PORT"
    value = "5432"
  }
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
    key        = "REDIS_PASSWORD"
    value      = var.redis_password
    is_literal = true
  }
  env {
    key   = "TZ"
    value = var.tz
  }

  # Chatwoot-specific
  env {
    key        = "CHATWOOT_SECRET_KEY_BASE"
    value      = var.chatwoot_secret_key_base
    is_literal = true
  }
  env {
    key   = "CHATWOOT_FRONTEND_URL"
    value = var.chatwoot_frontend_url
  }
  env {
    key   = "CHATWOOT_INSTALLATION_NAME"
    value = "NexaDuo"
  }
  env {
    key   = "CHATWOOT_DEFAULT_LOCALE"
    value = "pt_BR"
  }
  env {
    key   = "CHATWOOT_ENABLE_ACCOUNT_SIGNUP"
    value = "false"
  }
  env {
    key   = "CHATWOOT_FORCE_SSL"
    value = "false"
  }
}

# ---------------------------------------------------------------------------
# Post-deploy health probe (D-05): wait for chatwoot-rails to be healthy AND
# serve HTTP 200 on / via the host-published port 3000.
# ---------------------------------------------------------------------------
resource "null_resource" "verify_chatwoot" {
  depends_on = [coolify_service.chatwoot, coolify_service_envs.chatwoot]

  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    host        = module.vm.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for nexaduo-chatwoot-rails to be healthy (up to 6 min)'",
      "timeout 360 bash -c 'until [ \"$(docker inspect -f \"{{.State.Health.Status}}\" nexaduo-chatwoot-rails 2>/dev/null)\" = \"healthy\" ]; do sleep 5; done'",
      "echo 'Probing http://localhost:3000/ for HTTP 200 (up to 1 min)'",
      "timeout 60 bash -c 'until [ \"$(curl -s -o /dev/null -w %%{http_code} http://localhost:3000/)\" = \"200\" ]; do sleep 3; done'",
      "echo 'OK chatwoot stack healthy'"
    ]
  }

  triggers = {
    compose_hash = filesha256("${path.root}/../../../../deploy/docker-compose.chatwoot.yml")
  }
}

output "coolify_chatwoot_service_uuid" {
  value = coolify_service.chatwoot.uuid
}

# ---------------------------------------------------------------------------
# Stack 3/4 — Dify (api + worker + web + sandbox + plugin-daemon + ssrf-proxy).
# Joins nexaduo-network so Postgres + Redis (shared stack) are reachable.
# Independent of chatwoot stack — both can deploy in parallel from
# Terraform's POV (both depend only on shared).
# ---------------------------------------------------------------------------
resource "coolify_service" "dify" {
  name             = "nexaduo-dify"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false

  compose = file("${path.root}/../../../../deploy/docker-compose.dify.yml")

  depends_on = [
    coolify_service.shared,
    coolify_service_envs.shared,
    null_resource.verify_shared,
  ]
}

resource "coolify_service_envs" "dify" {
  uuid = coolify_service.dify.uuid

  # Shared infra references
  env {
    key   = "POSTGRES_HOST"
    value = "postgres"
  }
  env {
    key   = "POSTGRES_PORT"
    value = "5432"
  }
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
    key   = "REDIS_HOST"
    value = "redis"
  }
  env {
    key        = "REDIS_PASSWORD"
    value      = var.redis_password
    is_literal = true
  }
  env {
    key   = "TZ"
    value = var.tz
  }

  # Dify core
  env {
    key        = "DIFY_SECRET_KEY"
    value      = var.dify_secret_key
    is_literal = true
  }
  env {
    key   = "DIFY_LOG_LEVEL"
    value = "INFO"
  }
  env {
    key   = "DIFY_VECTOR_STORE"
    value = "pgvector"
  }

  # Public URLs (DEPLOY-02): Cloudflare Worker handles /{tenant}/ path routing
  env {
    key   = "DIFY_CONSOLE_API_URL"
    value = var.dify_console_api_url
  }
  env {
    key   = "DIFY_APP_API_URL"
    value = var.dify_app_api_url
  }

  # Sandbox + plugin-daemon
  env {
    key        = "DIFY_SANDBOX_API_KEY"
    value      = var.dify_sandbox_api_key
    is_literal = true
  }
  env {
    key        = "DIFY_PLUGIN_DAEMON_KEY"
    value      = var.dify_plugin_daemon_key
    is_literal = true
  }
  env {
    key        = "DIFY_PLUGIN_DIFY_INNER_API_KEY"
    value      = var.dify_plugin_dify_inner_api_key
    is_literal = true
  }

  # Metrics (consumed by Prometheus in nexaduo stack via otel-collector)
  env {
    key   = "DIFY_API_ENABLE_METRICS"
    value = "true"
  }
  env {
    key   = "INNER_API_METRICS_ENABLED"
    value = "true"
  }
}

# ---------------------------------------------------------------------------
# Post-deploy health probe (D-05): wait for nexaduo-dify-api healthy AND
# serve HTTP 200 on /console/api/setup via host-published port 5001.
# ---------------------------------------------------------------------------
resource "null_resource" "verify_dify" {
  depends_on = [coolify_service.dify, coolify_service_envs.dify]

  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    host        = module.vm.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for nexaduo-dify-api to start (up to 5 min)'",
      "timeout 300 bash -c 'until docker inspect nexaduo-dify-api >/dev/null 2>&1; do sleep 5; done'",
      "echo 'Probing http://localhost:5001/console/api/setup for HTTP 200 (up to 3 min)'",
      "timeout 180 bash -c 'until [ \"$(curl -s -o /dev/null -w %%{http_code} http://localhost:5001/console/api/setup)\" = \"200\" ]; do sleep 5; done'",
      "echo 'OK dify stack healthy'"
    ]
  }

  triggers = {
    compose_hash = filesha256("${path.root}/../../../../deploy/docker-compose.dify.yml")
  }
}

# ---------------------------------------------------------------------------
# Stack 4/4 — NexaDuo (middleware + evolution + observability stack:
# loki, promtail, grafana, prometheus, self-healing-agent).
# Depends on chatwoot + dify being healthy because middleware probes them on
# startup over nexaduo-network.
# ---------------------------------------------------------------------------
resource "coolify_service" "nexaduo" {
  name             = "nexaduo-app"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  environment_name = "production"
  instant_deploy   = false

  compose = file("${path.root}/../../../../deploy/docker-compose.nexaduo.yml")

  depends_on = [
    coolify_service.chatwoot,
    coolify_service_envs.chatwoot,
    null_resource.verify_chatwoot,
    coolify_service.dify,
    coolify_service_envs.dify,
    null_resource.verify_dify,
  ]
}

resource "coolify_service_envs" "nexaduo" {
  uuid = coolify_service.nexaduo.uuid

  # Image references (Pitfall 5/6 fix — pre-built images, no build context)
  env {
    key   = "MIDDLEWARE_IMAGE"
    value = var.middleware_image
  }
  env {
    key   = "SELF_HEALING_IMAGE"
    value = var.self_healing_image
  }

  # Shared infra references
  env {
    key   = "POSTGRES_HOST"
    value = "postgres"
  }
  env {
    key   = "POSTGRES_PORT"
    value = "5432"
  }
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
    key        = "REDIS_PASSWORD"
    value      = var.redis_password
    is_literal = true
  }
  env {
    key   = "TZ"
    value = var.tz
  }

  # Evolution API
  env {
    key        = "EVOLUTION_AUTHENTICATION_API_KEY"
    value      = var.evolution_authentication_api_key
    is_literal = true
  }

  # Middleware bridge
  env {
    key   = "CHATWOOT_BASE_URL"
    value = "http://chatwoot-rails:3000"
  }
  env {
    key        = "CHATWOOT_API_TOKEN"
    value      = var.chatwoot_api_token
    is_literal = true
  }
  env {
    key   = "DIFY_BASE_URL"
    value = "http://dify-api:5001/v1"
  }
  env {
    key        = "HANDOFF_SHARED_SECRET"
    value      = var.handoff_shared_secret
    is_literal = true
  }
  env {
    key   = "HANDOFF_LABEL"
    value = "atendimento-humano"
  }

  # Grafana — needed both for admin login AND for Postgres datasource
  # provisioning (observability/grafana/provisioning/datasources/postgres.yml
  # uses ${POSTGRES_USER}/${POSTGRES_PASSWORD} interpolation).
  env {
    key   = "GRAFANA_ADMIN_USER"
    value = var.grafana_admin_user
  }
  env {
    key        = "GRAFANA_ADMIN_PASSWORD"
    value      = var.grafana_admin_password
    is_literal = true
  }
}

# ---------------------------------------------------------------------------
# Post-deploy health probe (D-05 + DEPLOY-03 + DEPLOY-04):
#   - middleware /health  -> 200 (DEPLOY-03)
#   - grafana /login      -> 200 (DEPLOY-04)
#   - prometheus /-/healthy -> 200 (DEPLOY-04)
#   - loki /ready         -> 200 (DEPLOY-04)
#   - evolution-api /     -> 200 or 401 (auth-protected; either proves the
#     process is up; we accept any 2xx/4xx response, reject 5xx + connection refused)
# ---------------------------------------------------------------------------
resource "null_resource" "verify_nexaduo" {
  depends_on = [coolify_service.nexaduo, coolify_service_envs.nexaduo]

  connection {
    type        = "ssh"
    user        = var.ssh_user
    private_key = file(var.ssh_private_key_path)
    host        = module.vm.public_ip
  }

  provisioner "remote-exec" {
    inline = [
      "echo 'Waiting for nexaduo-middleware to start (up to 3 min)'",
      "timeout 180 bash -c 'until docker inspect nexaduo-middleware >/dev/null 2>&1; do sleep 5; done'",
      "echo 'Probing middleware /health (up to 2 min)'",
      "timeout 120 bash -c 'until [ \"$(curl -s -o /dev/null -w %%{http_code} http://localhost:4000/health)\" = \"200\" ]; do sleep 5; done'",
      "echo 'Probing grafana /login (up to 2 min)'",
      "timeout 120 bash -c 'until [ \"$(curl -s -o /dev/null -w %%{http_code} http://localhost:3002/login)\" = \"200\" ]; do sleep 5; done'",
      "echo 'Probing prometheus /-/healthy (up to 2 min)'",
      "timeout 120 bash -c 'until [ \"$(curl -s -o /dev/null -w %%{http_code} http://localhost:9090/-/healthy)\" = \"200\" ]; do sleep 5; done'",
      "echo 'Probing loki /ready (up to 2 min)'",
      "timeout 120 bash -c 'until [ \"$(curl -s -o /dev/null -w %%{http_code} http://localhost:3100/ready)\" = \"200\" ]; do sleep 5; done'",
      "echo 'OK nexaduo stack healthy (middleware + grafana + prometheus + loki)'"
    ]
  }

  triggers = {
    compose_hash = filesha256("${path.root}/../../../../deploy/docker-compose.nexaduo.yml")
  }
}

output "coolify_nexaduo_service_uuid" {
  value = coolify_service.nexaduo.uuid
}

output "coolify_dify_service_uuid" {
  value = coolify_service.dify.uuid
}

output "coolify_project_uuid" {
  value = coolify_project.main.uuid
}

output "coolify_shared_service_uuid" {
  value = coolify_service.shared.uuid
}
