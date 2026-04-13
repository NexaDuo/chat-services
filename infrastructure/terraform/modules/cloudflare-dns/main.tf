terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "zone_id" { type = string }
variable "name" { type = string }  # e.g. chat
variable "value" { type = string } # IP address

resource "cloudflare_record" "root" {
  zone_id = var.zone_id
  name    = var.name
  content = var.value
  type    = "A"
  proxied = true
}

resource "cloudflare_record" "wildcard" {
  zone_id = var.zone_id
  name    = "*.${var.name}"
  content = var.value
  type    = "A"
  proxied = true
}
