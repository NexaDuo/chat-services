# =============================================================================
# Phase 5 — Coolify service deployments (Tenant Layer)
# =============================================================================

# Look up the local Coolify server (single-server setup; index [0]).
data "coolify_servers" "main" {}

resource "coolify_project" "main" {
  name = "NexaDuo Chat Services"
}

# ---------------------------------------------------------------------------
# Stack 1/4 — Shared (Postgres 16+pgvector, Redis 7).
# ---------------------------------------------------------------------------
resource "coolify_service" "shared" {
  name             = "nexaduo-shared"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = "production"
  instant_deploy   = true

  compose = file("${path.root}/../../../../../deploy/docker-compose.shared.yml")

  lifecycle {
    ignore_changes = [
      server_uuid,
      project_uuid,
      destination_uuid,
      environment_name,
      compose,
    ]
  }
}

resource "coolify_service_envs" "shared" {
  uuid = coolify_service.shared.uuid

  env {
    key   = "POSTGRES_USER"
    value = var.postgres_user
  }
  env {
    key        = "POSTGRES_PASSWORD"
    value      = data.google_secret_manager_secret_version.postgres_password.secret_data
    is_literal = true
  }
  env {
    key        = "REDIS_PASSWORD"
    value      = data.google_secret_manager_secret_version.redis_password.secret_data
    is_literal = true
  }
  env {
    key   = "TZ"
    value = var.tz
  }
  env {
    key        = "TUNNEL_TOKEN"
    value      = data.google_secret_manager_secret_version.tunnel_token.secret_data
    is_literal = true
  }
}

# ---------------------------------------------------------------------------
# Stack 2/4 — Chatwoot
# ---------------------------------------------------------------------------
resource "coolify_service" "chatwoot" {
  name             = "nexaduo-chatwoot"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = "production"
  instant_deploy   = true

  compose = file("${path.root}/../../../../../deploy/docker-compose.chatwoot.yml")

  depends_on = [
    coolify_service.shared,
    coolify_service_envs.shared,
  ]

  lifecycle {
    ignore_changes = [
      server_uuid,
      project_uuid,
      destination_uuid,
      environment_name,
      compose,
    ]
  }
}

resource "coolify_service_envs" "chatwoot" {
  uuid = coolify_service.chatwoot.uuid

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
    value      = data.google_secret_manager_secret_version.postgres_password.secret_data
    is_literal = true
  }
  env {
    key        = "REDIS_PASSWORD"
    value      = data.google_secret_manager_secret_version.redis_password.secret_data
    is_literal = true
  }
  env {
    key   = "REDIS_PORT"
    value = "6379"
  }
  env {
    key   = "TZ"
    value = var.tz
  }
  env {
    key        = "CHATWOOT_SECRET_KEY_BASE"
    value      = data.google_secret_manager_secret_version.chatwoot_secret_key_base.secret_data
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
# Stack 3/4 — Dify
# ---------------------------------------------------------------------------
resource "coolify_service" "dify" {
  name             = "nexaduo-dify"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = "production"
  instant_deploy   = true

  compose = file("${path.root}/../../../../../deploy/docker-compose.dify.yml")

  depends_on = [
    coolify_service.shared,
    coolify_service_envs.shared,
  ]

  lifecycle {
    ignore_changes = [
      server_uuid,
      project_uuid,
      destination_uuid,
      environment_name,
      compose,
    ]
  }
}

resource "coolify_service_envs" "dify" {
  uuid = coolify_service.dify.uuid

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
    value      = data.google_secret_manager_secret_version.postgres_password.secret_data
    is_literal = true
  }
  env {
    key   = "REDIS_HOST"
    value = "redis"
  }
  env {
    key        = "REDIS_PASSWORD"
    value      = data.google_secret_manager_secret_version.redis_password.secret_data
    is_literal = true
  }
  env {
    key   = "REDIS_PORT"
    value = "6379"
  }
  env {
    key   = "TZ"
    value = var.tz
  }
  env {
    key        = "DIFY_SECRET_KEY"
    value      = data.google_secret_manager_secret_version.dify_secret_key.secret_data
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
  env {
    key   = "DIFY_CONSOLE_API_URL"
    value = var.dify_console_api_url
  }
  env {
    key   = "DIFY_APP_API_URL"
    value = var.dify_app_api_url
  }
  env {
    key   = "HOSTNAME"
    value = "0.0.0.0"
  }
  env {
    key        = "DIFY_SANDBOX_API_KEY"
    value      = data.google_secret_manager_secret_version.dify_sandbox_api_key.secret_data
    is_literal = true
  }
  env {
    key        = "DIFY_PLUGIN_DAEMON_KEY"
    value      = data.google_secret_manager_secret_version.dify_plugin_daemon_key.secret_data
    is_literal = true
  }
  env {
    key        = "DIFY_PLUGIN_DIFY_INNER_API_KEY"
    value      = data.google_secret_manager_secret_version.dify_plugin_dify_inner_api_key.secret_data
    is_literal = true
  }
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
# Stack 4/4 — NexaDuo
# ---------------------------------------------------------------------------
resource "coolify_service" "nexaduo" {
  name             = "nexaduo-app"
  server_uuid      = tolist(data.coolify_servers.main.servers)[0].uuid
  project_uuid     = coolify_project.main.uuid
  destination_uuid = data.google_secret_manager_secret_version.coolify_destination_uuid.secret_data
  environment_name = "production"
  instant_deploy   = true

  compose = file("${path.root}/../../../../../deploy/docker-compose.nexaduo.yml")


  depends_on = [
    coolify_service.chatwoot,
    coolify_service_envs.chatwoot,
    coolify_service.dify,
    coolify_service_envs.dify,
  ]

  lifecycle {
    ignore_changes = [
      server_uuid,
      project_uuid,
      destination_uuid,
      environment_name,
      compose,
    ]
  }
}

resource "coolify_service_envs" "nexaduo" {
  uuid = coolify_service.nexaduo.uuid

  env {
    key   = "MIDDLEWARE_IMAGE"
    value = var.middleware_image
  }
  env {
    key   = "SELF_HEALING_IMAGE"
    value = var.self_healing_image
  }
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
    value      = data.google_secret_manager_secret_version.postgres_password.secret_data
    is_literal = true
  }
  env {
    key        = "REDIS_PASSWORD"
    value      = data.google_secret_manager_secret_version.redis_password.secret_data
    is_literal = true
  }
  env {
    key   = "REDIS_PORT"
    value = "6379"
  }
  env {
    key   = "TZ"
    value = var.tz
  }
  env {
    key        = "EVOLUTION_AUTHENTICATION_API_KEY"
    value      = data.google_secret_manager_secret_version.evolution_authentication_api_key.secret_data
    is_literal = true
  }
  env {
    key   = "CHATWOOT_BASE_URL"
    value = "http://chatwoot-rails:3000"
  }
  env {
    key        = "CHATWOOT_API_TOKEN"
    value      = data.google_secret_manager_secret_version.chatwoot_api_token.secret_data
    is_literal = true
  }
  env {
    key   = "DIFY_BASE_URL"
    value = "http://dify-api:5001/v1"
  }
  env {
    key        = "HANDOFF_SHARED_SECRET"
    value      = data.google_secret_manager_secret_version.handoff_shared_secret.secret_data
    is_literal = true
  }
  env {
    key   = "HANDOFF_LABEL"
    value = "atendimento-humano"
  }
  env {
    key   = "GRAFANA_ADMIN_USER"
    value = var.grafana_admin_user
  }
  env {
    key        = "GRAFANA_ADMIN_PASSWORD"
    value      = data.google_secret_manager_secret_version.grafana_admin_password.secret_data
    is_literal = true
  }
}

output "coolify_chatwoot_service_uuid" {
  value = coolify_service.chatwoot.uuid
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
