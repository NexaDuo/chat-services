# Service account that GitHub Actions impersonates via Workload Identity
# Federation to push images into Artifact Registry. No JSON key is created.
resource "google_service_account" "publisher" {
  project      = var.project_id
  account_id   = var.service_account_id
  display_name = "GitHub Actions publisher for ${var.github_repository}"
}

resource "google_artifact_registry_repository_iam_member" "writer" {
  project    = var.project_id
  location   = var.artifact_registry_location
  repository = var.artifact_registry_repository_id
  role       = "roles/artifactregistry.writer"
  member     = "serviceAccount:${google_service_account.publisher.email}"
}

# OIDC pool + provider — binds GitHub's OIDC tokens to impersonatable identities.
resource "google_iam_workload_identity_pool" "github" {
  project                   = var.project_id
  workload_identity_pool_id = var.pool_id
  display_name              = "GitHub Actions"
  description               = "OIDC federation for repos under the NexaDuo org"
}

resource "google_iam_workload_identity_pool_provider" "github" {
  project                            = var.project_id
  workload_identity_pool_id          = google_iam_workload_identity_pool.github.workload_identity_pool_id
  workload_identity_pool_provider_id = var.provider_id
  display_name                       = var.provider_id

  oidc {
    issuer_uri = "https://token.actions.githubusercontent.com"
  }

  attribute_mapping = {
    "google.subject"       = "assertion.sub"
    "attribute.repository" = "assertion.repository"
    "attribute.ref"        = "assertion.ref"
  }

  # Restrict the provider to this specific repository so other repos in the
  # org cannot impersonate the publisher SA.
  attribute_condition = "assertion.repository == \"${var.github_repository}\""
}

# Allow the GitHub repo (via WIF) to impersonate the publisher SA.
resource "google_service_account_iam_member" "gh_wif_user" {
  service_account_id = google_service_account.publisher.name
  role               = "roles/iam.workloadIdentityUser"
  member             = "principalSet://iam.googleapis.com/${google_iam_workload_identity_pool.github.name}/attribute.repository/${var.github_repository}"
}

output "service_account_email" {
  value = google_service_account.publisher.email
}

output "workload_identity_provider" {
  description = "Full resource name to pass as workload_identity_provider in the GitHub workflow auth step"
  value       = google_iam_workload_identity_pool_provider.github.name
}
