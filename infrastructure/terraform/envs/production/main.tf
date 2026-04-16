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

output "coolify_project_uuid" {
  value = coolify_project.main.uuid
}

output "coolify_shared_service_uuid" {
  value = coolify_service.shared.uuid
}
