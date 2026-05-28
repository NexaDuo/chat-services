locals {
  env       = terraform.workspace
  is_prod   = local.env == "production" || local.env == "default"
  vm_suffix = local.is_prod ? "" : "-${local.env}"
  vm_name   = "${var.app_name}${local.vm_suffix}"

  # Scaled down sizes for non-production environments to minimize costs
  machine_type = local.is_prod ? var.machine_type : "e2-medium"
  disk_size    = local.is_prod ? var.disk_size : 30

  # Environment suffix for subdomains
  dns_suffix = local.is_prod ? "" : "-stg"
}

module "vm" {
  source = "../../../modules/gcp-vm"

  project_id            = var.gcp_project_id
  region                = var.gcp_region
  zone                  = var.gcp_zone
  name                  = local.vm_name
  machine_type          = local.machine_type
  disk_size             = local.disk_size
  ssh_user              = var.ssh_user
  ssh_key               = var.ssh_key
  service_account_email = "${var.gcp_project_number}-compute@developer.gserviceaccount.com"
}

module "dns_chat" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "chat${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_dify" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "dify${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_grafana" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "grafana${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_evolution" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "evolution${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_middleware" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "middleware${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "dns_coolify" {
  source = "../../../modules/cloudflare-dns"

  zone_id = var.cloudflare_zone_id
  name    = "coolify${local.dns_suffix}"
  value   = "${module.tunnel.tunnel_id}.cfargotunnel.com"
  proxied = true
}

module "backup_storage" {
  source = "../../../modules/gcp-storage"

  project_id  = var.gcp_project_id
  region      = var.gcp_region
  bucket_name = local.is_prod ? var.backup_bucket_name : "${var.backup_bucket_name}-${local.env}"
}

module "tunnel" {
  source = "../../../modules/cloudflare-tunnel"

  account_id  = var.cloudflare_account_id
  name        = "${var.app_name}-${local.env}-tunnel"
  zone_id     = var.cloudflare_zone_id
  base_domain = var.base_domain
  proxied     = true
}

resource "google_project_service" "required" {
  for_each = toset([
    "artifactregistry.googleapis.com",
    "iamcredentials.googleapis.com",
    "sts.googleapis.com",
  ])

  project            = var.gcp_project_id
  service            = each.value
  disable_on_destroy = false
}

module "artifact_registry" {
  source = "../../../modules/gcp-artifact-registry"

  project_id    = var.gcp_project_id
  location      = var.gcp_region
  repository_id = local.is_prod ? var.artifact_registry_repository_id : "${var.artifact_registry_repository_id}-${local.env}"

  depends_on = [google_project_service.required]
}

module "gh_publisher" {
  count  = local.is_prod ? 1 : 0
  source = "../../../modules/gcp-gh-publisher"

  project_id                      = var.gcp_project_id
  github_repository               = var.github_repository
  artifact_registry_location      = module.artifact_registry.location
  artifact_registry_repository_id = module.artifact_registry.repository_id
}

resource "google_artifact_registry_repository_iam_member" "vm_reader" {
  project    = var.gcp_project_id
  location   = module.artifact_registry.location
  repository = module.artifact_registry.repository_id
  role       = "roles/artifactregistry.reader"
  member     = "serviceAccount:${var.gcp_project_number}-compute@developer.gserviceaccount.com"
}

output "tunnel_token" {
  value     = module.tunnel.tunnel_token
  sensitive = true
}

output "tunnel_id" {
  value = module.tunnel.tunnel_id
}

output "artifact_registry_url" {
  description = "Image prefix for the tenant layer: <url>/<image>:<tag>"
  value       = module.artifact_registry.repository_url
}

output "gh_publisher_service_account" {
  value = local.is_prod ? module.gh_publisher[0].service_account_email : ""
}

output "gh_workload_identity_provider" {
  description = "Pass this as workload_identity_provider in .github/workflows/publish-images.yml"
  value       = local.is_prod ? module.gh_publisher[0].workload_identity_provider : ""
}
