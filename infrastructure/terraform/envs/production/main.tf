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

output "coolify_project_uuid" {
  value = coolify_project.main.uuid
}

output "coolify_shared_service_uuid" {
  value = coolify_service.shared.uuid
}
