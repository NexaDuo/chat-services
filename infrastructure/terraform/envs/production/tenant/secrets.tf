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

# Platform App token (super-admin) required by the middleware to call the
# Chatwoot Platform API (/platform/api/v1/*) during tenant provisioning. The
# regular account api_token (chatwoot_api_token) is NOT authorized there and
# yields 401, which is why provisioning failed before this was wired up.
data "google_secret_manager_secret_version" "chatwoot_platform_token" {
  secret = "chatwoot_platform_token"
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

# Coolify connection secrets are per-environment to stop staging deploys
# (triggered by PRs) from clobbering production's values mid-deploy. bootstrap
# writes coolify_<name>_<env>; here we read the workspace-matching copy.
data "google_secret_manager_secret_version" "coolify_api_token" {
  secret = "coolify_api_token_${local.env}"
}

data "google_secret_manager_secret_version" "coolify_url" {
  secret = "coolify_url_${local.env}"
}

data "terraform_remote_state" "foundation" {
  backend   = "gcs"
  workspace = terraform.workspace

  config = {
    bucket = "nexaduo-terraform-state"
    prefix = "terraform/foundation"
  }
}

data "google_secret_manager_secret_version" "google_oauth_client_id" {
  secret = "google_oauth_client_id"
}

data "google_secret_manager_secret_version" "google_oauth_client_secret" {
  secret = "google_oauth_client_secret"
}

# Instagram (Meta) app credentials for Chatwoot's native Instagram-Login channel.
# Installation-wide (Chatwoot reads them via GlobalConfigService): a single Meta app
# serves every tenant; per-tenant connection is a manual OAuth in each Chatwoot account.
data "google_secret_manager_secret_version" "instagram_app_id" {
  secret = "instagram_app_id"
}

data "google_secret_manager_secret_version" "instagram_app_secret" {
  secret = "instagram_app_secret"
}

data "google_secret_manager_secret_version" "instagram_verify_token" {
  secret = "instagram_verify_token"
}

data "google_secret_manager_secret_version" "admin_password" {
  secret = "admin_password"
}

