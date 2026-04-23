# infrastructure/terraform/envs/production/tenant/secrets.tf

# ---------------------------------------------------------------------------
# SSOT: GCP Secret Manager
# All sensitive variables are fetched dynamically from Secret Manager 
# based on the secret names established during migration.
# ---------------------------------------------------------------------------

data "google_secret_manager_secret_version" "postgres_password" {
  secret = "postgres_password"
}

data "google_secret_manager_secret_version" "redis_password" {
  secret = "redis_password"
}

data "google_secret_manager_secret_version" "chatwoot_secret_key_base" {
  secret = "chatwoot_secret_key_base"
}

data "google_secret_manager_secret_version" "chatwoot_api_token" {
  secret = "chatwoot_api_token"
}

data "google_secret_manager_secret_version" "dify_secret_key" {
  secret = "dify_secret_key"
}

data "google_secret_manager_secret_version" "dify_sandbox_api_key" {
  secret = "dify_sandbox_api_key"
}

data "google_secret_manager_secret_version" "dify_plugin_daemon_key" {
  secret = "dify_plugin_daemon_key"
}

data "google_secret_manager_secret_version" "dify_plugin_dify_inner_api_key" {
  secret = "dify_plugin_dify_inner_api_key"
}

data "google_secret_manager_secret_version" "evolution_authentication_api_key" {
  secret = "evolution_authentication_api_key"
}

data "google_secret_manager_secret_version" "handoff_shared_secret" {
  secret = "handoff_shared_secret"
}

data "google_secret_manager_secret_version" "grafana_admin_password" {
  secret = "grafana_admin_password"
}

data "google_secret_manager_secret_version" "coolify_api_token" {
  secret = "coolify_api_token"
}

data "google_secret_manager_secret_version" "coolify_destination_uuid" {
  secret = "coolify_destination_uuid"
}

data "google_secret_manager_secret_version" "coolify_url" {
  secret = "coolify_url"
}

data "google_secret_manager_secret_version" "tunnel_token" {
  secret = "tunnel_token"
}
