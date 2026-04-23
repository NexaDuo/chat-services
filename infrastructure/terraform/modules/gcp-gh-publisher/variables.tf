variable "project_id" {
  type = string
}

variable "service_account_id" {
  type    = string
  default = "gh-publisher"
}

variable "github_repository" {
  description = "owner/repo of the GitHub repository allowed to impersonate this SA (e.g. NexaDuo/chat-services)"
  type        = string
}

variable "pool_id" {
  type    = string
  default = "github"
}

variable "provider_id" {
  type    = string
  default = "nexaduo-chat-services"
}

variable "artifact_registry_location" {
  type = string
}

variable "artifact_registry_repository_id" {
  type = string
}
