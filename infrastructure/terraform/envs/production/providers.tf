terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    coolify = {
      source  = "SierraJC/coolify"
      version = "0.10.2"
    }
  }
}

provider "google" {
  project     = var.gcp_project_id
  region      = var.gcp_region
  credentials = var.gcp_credentials_file != null ? file(var.gcp_credentials_file) : null
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

provider "coolify" {
  endpoint = "http://${module.vm.public_ip}:8000/api/v1"
  token    = var.coolify_api_token
}
