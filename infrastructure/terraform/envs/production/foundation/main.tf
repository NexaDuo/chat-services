module "vm" {
  source = "../../../modules/gcp-vm"

  project_id   = var.gcp_project_id
  region       = var.gcp_region
  zone         = var.gcp_zone
  name         = var.app_name
  machine_type = var.machine_type
  disk_size    = var.disk_size
  ssh_user     = var.ssh_user
  ssh_key      = var.ssh_key
}

module "dns_chat" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "chat"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_dify" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "dify"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_grafana" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "grafana"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "backup_storage" {
  source = "../../../modules/gcp-storage"

  project_id  = var.gcp_project_id
  region      = var.gcp_region
  bucket_name = var.backup_bucket_name
}

module "tunnel" {
  source = "../../../modules/cloudflare-tunnel"

  account_id  = var.cloudflare_account_id
  name        = "${var.app_name}-tunnel"
  zone_id     = var.cloudflare_zone_id
  base_domain = var.base_domain
  proxied     = true
}
