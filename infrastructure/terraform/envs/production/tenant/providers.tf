terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
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

provider "coolify" {
  endpoint = data.google_secret_manager_secret_version.coolify_url.secret_data
  token    = data.google_secret_manager_secret_version.coolify_api_token.secret_data
}
