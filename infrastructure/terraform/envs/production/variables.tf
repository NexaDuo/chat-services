variable "gcp_credentials_file" {
  type    = string
  default = null
}

variable "gcp_project_id" {
  type = string
}

variable "gcp_region" {
  type    = string
  default = "us-central1"
}

variable "gcp_zone" {
  type    = string
  default = "us-central1-b"
}

variable "app_name" {
  type    = string
  default = "nexaduo-chat-services"
}

variable "machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "disk_size" {
  type    = number
  default = 50
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_key" {
  type = string
}

variable "cloudflare_api_token" {
  type      = string
  sensitive = true
}

variable "cloudflare_account_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
}

variable "coolify_api_token" {
  type      = string
  sensitive = true
}

variable "dns_subdomain" {
  type    = string
  default = "chat"
}

variable "backup_bucket_name" {
  type    = string
  default = "nexaduo-coolify-backups"
}

variable "base_domain" {
  type    = string
  default = "nexaduo.com"
}

# ---------------------------------------------------------- Phase 5: Coolify stack secrets ---
variable "ssh_private_key_path" {
  type        = string
  description = "Path to the private SSH key file used by null_resource provisioners (matches public key in var.ssh_key)."
}

variable "postgres_user" {
  type    = string
  default = "postgres"
}

variable "postgres_password" {
  type      = string
  sensitive = true
}

variable "redis_password" {
  type      = string
  sensitive = true
}

variable "tz" {
  type    = string
  default = "America/Sao_Paulo"
}

# Chatwoot
variable "chatwoot_secret_key_base" {
  type      = string
  sensitive = true
}

variable "chatwoot_frontend_url" {
  type    = string
  default = "https://chat.nexaduo.com"
}

variable "chatwoot_api_token" {
  type      = string
  sensitive = true
}

# Dify
variable "dify_secret_key" {
  type      = string
  sensitive = true
}

variable "dify_console_api_url" {
  type    = string
  default = "https://dify.nexaduo.com"
}

variable "dify_app_api_url" {
  type    = string
  default = "https://dify.nexaduo.com"
}

variable "dify_sandbox_api_key" {
  type      = string
  sensitive = true
}

variable "dify_plugin_daemon_key" {
  type      = string
  sensitive = true
}

variable "dify_plugin_dify_inner_api_key" {
  type      = string
  sensitive = true
}

# Evolution / Middleware / Observability
variable "evolution_authentication_api_key" {
  type      = string
  sensitive = true
}

variable "handoff_shared_secret" {
  type      = string
  sensitive = true
}

variable "grafana_admin_user" {
  type    = string
  default = "admin"
}

variable "grafana_admin_password" {
  type      = string
  sensitive = true
}

# Image registry tags (Phase 5 build-context workaround)
variable "middleware_image" {
  type        = string
  description = "Pre-built middleware image with registry prefix, e.g. ghcr.io/nexaduo/middleware:0.1.0"
}

variable "self_healing_image" {
  type        = string
  description = "Pre-built self-healing-agent image with registry prefix"
}
