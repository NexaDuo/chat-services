# Plan: Secret Management with GCP Secret Manager

Migrate secrets from `terraform.tfvars` to GCP Secret Manager (SSOT) and integrate it consistently across local development and Coolify (production).

## 1. Unified Management Strategy
- [x] Create `scripts/migrate-to-gcp-secrets.sh` to push local `.tfvars` to GCP Secret Manager.
- [x] Create `scripts/sync-secrets-gcp.sh` to pull GCP secrets to a local `.env`.
- [x] Update Terraform to fetch secrets from GCP and inject into Coolify.
- [x] Ensure both local and production environments pull from the same GCP project/secret version.

## 2. Infrastructure Setup & Verification
- [x] Enable Secret Manager API in the GCP project.
- [x] Migrate all sensitive keys from `terraform.tfvars` to GCP.
- [x] Document the authentication requirement (`gcloud auth login`).

## 3. Terraform & Coolify Integration
- [x] Update `infrastructure/terraform/envs/production/main.tf` to use `data "google_secret_manager_secret_version"` for all sensitive values.
- [x] Map these fetched secrets to `coolify_service_envs` resources.
- [x] Remove sensitive defaults from `variables.tf`.

## 4. Cleanup & Validation
- [x] Verify `terraform plan` no longer needs `.tfvars` for sensitive data (fetching confirmed).
- [x] Ensure `.env` and `*.tfvars` are strictly ignored.
- [x] Confirm `scripts/sync-secrets-gcp.sh` correctly populates local `.env`.
