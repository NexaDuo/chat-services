module "vm" {
  source = "../../modules/gcp-vm"

  project_id   = var.gcp_project_id
  region       = var.gcp_region
  zone         = var.gcp_zone
  name         = var.app_name
  machine_type = var.machine_type
  disk_size    = var.disk_size
  ssh_user     = var.ssh_user
  ssh_key      = var.ssh_key
}

module "dns" {
  source = "../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = var.dns_subdomain
  value   = module.vm.public_ip
  proxied = true
}

module "tunnel" {
  source = "../../modules/cloudflare-tunnel"

  account_id  = var.cloudflare_account_id
  name        = "${var.app_name}-tunnel"
  zone_id     = var.cloudflare_zone_id
  base_domain = var.base_domain
  proxied     = true
}

output "public_ip" {
  value = module.vm.public_ip
}

output "tunnel_token" {
  value     = module.tunnel.tunnel_token
  sensitive = true
}
