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

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "postgres_user" {
  type    = string
  default = "postgres"
}

variable "tz" {
  type    = string
  default = "America/Sao_Paulo"
}

variable "chatwoot_frontend_url" {
  type    = string
  default = "https://chat.nexaduo.com"
}

variable "dify_console_api_url" {
  type    = string
  default = "https://dify.nexaduo.com"
}

variable "dify_app_api_url" {
  type    = string
  default = "https://dify.nexaduo.com"
}

variable "grafana_admin_user" {
  type    = string
  default = "alexandre@nexaduo.com"
}

variable "middleware_image" {
  type        = string
  description = "Pre-built middleware image with registry prefix"
}

variable "self_healing_image" {
  type        = string
  description = "Pre-built self-healing-agent image with registry prefix"
}

variable "base_domain" {
  type    = string
  default = "nexaduo.com"
}

# UUIDs of the pre-existing Coolify services, keyed by stack
# (shared/chatwoot/dify/nexaduo). The Coolify provider (v0.10.2) cannot UPDATE a
# service (it sends destination_uuid in the payload, which Coolify rejects), so
# services are created/managed out-of-band and only their env vars are managed
# here via coolify_service_envs. Populate per environment from the
# terraform_tfvars_<env> Secret Manager value.
variable "coolify_service_uuids" {
  type        = map(string)
  description = "Pre-existing Coolify service UUIDs by stack (shared, chatwoot, dify, nexaduo)."
}

