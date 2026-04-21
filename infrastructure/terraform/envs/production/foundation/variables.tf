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

variable "base_domain" {
  type    = string
  default = "nexaduo.com"
}

variable "backup_bucket_name" {
  type    = string
  default = "nexaduo-coolify-backups"
}
