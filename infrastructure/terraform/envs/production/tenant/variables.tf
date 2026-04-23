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
  default = "admin"
}

variable "middleware_image" {
  type        = string
  description = "Pre-built middleware image with registry prefix"
}

variable "self_healing_image" {
  type        = string
  description = "Pre-built self-healing-agent image with registry prefix"
}
