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

variable "cloudflare_account_id" {
  type = string
}

variable "cloudflare_zone_id" {
  type = string
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

# ---------------------------------------------------------- Phase 5: Coolify stack non-secrets ---
variable "ssh_private_key_path" {
  type        = string
  description = "Path to the private SSH key file used by null_resource provisioners (matches public key in var.ssh_key)."
}

variable "postgres_user" {
  type    = string
  default = "postgres"
}

variable "tz" {
  type    = string
  default = "America/Sao_Paulo"
}

# Chatwoot
variable "chatwoot_frontend_url" {
  type    = string
  default = "https://chat.nexaduo.com"
}

# Dify
variable "dify_console_api_url" {
  type    = string
  default = "https://dify.nexaduo.com"
}

variable "dify_app_api_url" {
  type    = string
  default = "https://dify.nexaduo.com"
}

# Evolution / Middleware / Observability
variable "grafana_admin_user" {
  type    = string
  default = "admin"
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
