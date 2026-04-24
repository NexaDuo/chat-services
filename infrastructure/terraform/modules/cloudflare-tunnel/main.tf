terraform {
  required_providers {
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
  }
}

variable "account_id" {
  type = string
}

variable "name" {
  type = string
}

variable "zone_id" {
  type = string
}

variable "base_domain" {
  type = string # e.g. chat.nexaduo.com
}

variable "proxied" {
  type    = bool
  default = true
}

resource "random_id" "tunnel_secret" {
  byte_length = 32
}

resource "cloudflare_zero_trust_tunnel_cloudflared" "main" {
  account_id = var.account_id
  name       = var.name
  secret     = random_id.tunnel_secret.b64_std
}

resource "cloudflare_zero_trust_tunnel_cloudflared_config" "config" {
  account_id = var.account_id
  tunnel_id  = cloudflare_zero_trust_tunnel_cloudflared.main.id

  config {
    # Ingress rules
    ingress_rule {
      hostname = "coolify.${var.base_domain}"
      path     = "/app/*"
      service  = "http://coolify-realtime:6001"
    }
    ingress_rule {
      hostname = "coolify.${var.base_domain}"
      service  = "http://coolify-proxy:80"
    }
    ingress_rule {
      hostname = "chat.${var.base_domain}"
      service  = "http://coolify-proxy:80"
    }
    ingress_rule {
      hostname = "dify.${var.base_domain}"
      service  = "http://coolify-proxy:80"
    }
    ingress_rule {
      hostname = "grafana.${var.base_domain}"
      service  = "http://coolify-proxy:80"
    }
    ingress_rule {
      service = "http_status:404"
    }
  }
}

# CNAME para o painel do Coolify
resource "cloudflare_record" "coolify_cname" {
  zone_id = var.zone_id
  name    = "coolify"
  content = "${cloudflare_zero_trust_tunnel_cloudflared.main.id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = var.proxied
}

output "tunnel_id" {
  value = cloudflare_zero_trust_tunnel_cloudflared.main.id
}

output "tunnel_token" {
  value     = cloudflare_zero_trust_tunnel_cloudflared.main.tunnel_token
  sensitive = true
}

output "tunnel_name" {
  value = cloudflare_zero_trust_tunnel_cloudflared.main.name
}
