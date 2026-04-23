resource "google_artifact_registry_repository" "main" {
  project       = var.project_id
  location      = var.location
  repository_id = var.repository_id
  format        = "DOCKER"
  description   = "NexaDuo container images (middleware, self-healing-agent, future services)."
}

output "repository_url" {
  description = "Fully qualified Artifact Registry path used as the image prefix: <location>-docker.pkg.dev/<project>/<repo>"
  value       = "${var.location}-docker.pkg.dev/${var.project_id}/${google_artifact_registry_repository.main.repository_id}"
}

output "repository_id" {
  value = google_artifact_registry_repository.main.repository_id
}

output "location" {
  value = var.location
}
