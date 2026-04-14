terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "zone_id" {
  type = string
}

variable "name" {
  type = string # e.g. chat
}

variable "value" {
  type = string # IP address
}

variable "proxied" {
  type    = bool
  default = true
}

resource "cloudflare_record" "root" {
  zone_id = var.zone_id
  name    = var.name
  content = var.value
  type    = "CNAME"
  proxied = var.proxied
}
