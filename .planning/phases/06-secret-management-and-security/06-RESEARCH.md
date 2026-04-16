# Phase 06: Secret Management & Security Hardening - Research

**Researched:** 2026-04-16
**Domain:** Secret Management, Infrastructure-as-Code (Terraform), Google Cloud Platform (GCP)
**Confidence:** HIGH

## Summary

This research investigates the integration of GCP Secret Manager into a Terraform-managed stack. The primary goal is to eliminate sensitive data from `terraform.tfvars` files and automate secret injection across local development and production environments.

After comparing various options, **GCP Secret Manager** is the chosen solution due to its native integration with the existing GCP infrastructure, robust IAM-based security, and lower operational overhead compared to other self-hosted alternatives.

**Primary recommendation:** Use **GCP Secret Manager** as the single source of truth for secrets. Leverage Terraform's `google_secret_manager_secret_version` data source for production injection and implement a local synchronization script (`sync-secrets-gcp.sh`) for development parity.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- [D-06-01]: Use **GCP Secret Manager** for secret management.
- [D-06-02]: Leverage GCP IAM for secure access control.
- [D-06-03]: Update Terraform to use the `google` provider to fetch secrets.

### the agent's Discretion
- Selection of secret naming convention.
- Implementation details for local synchronization.
- Strategy for secret migration from `.tfvars`.

</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| VAULT-01 | Securely store all infrastructure and application secrets in GCP Secret Manager. | Verified GCP Secret Manager capabilities. |
| VAULT-02 | Eliminate local `.tfvars` files for sensitive data in production. | `scripts/migrate-to-gcp-secrets.sh` verified for migration. |
| VAULT-03 | Integrate the vault with Terraform for automatic secret injection. | `google_secret_manager_secret_version` data source confirmed. |
| VAULT-04 | Provide local dev parity. | `scripts/sync-secrets-gcp.sh` implemented to populate local `.env`. |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Secret Storage | GCP Secret Manager | GCP (IAM) | GCP handles durability and encryption; IAM handles access. |
| Secret Retrieval | Terraform (Provider) | gcloud CLI | Terraform for IaC; CLI for local developer sync. |
| Access Control | GCP IAM | — | Native GCP identity management. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| GCP Secret Manager | N/A (SaaS) | Secret Vault | Native GCP service, zero maintenance. |
| Terraform | v1.5.0+ | IaC | Standard for GCP resource management. |
| Google Provider | Latest | Terraform Plugin | Required for interacting with GCP APIs. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| gcloud CLI | Latest | Secret Migration/Sync | For developer access and automation scripts. |

## Architecture Patterns

### Recommended Project Structure
```
infrastructure/terraform/
└── envs/production/
    ├── main.tf             # Use 'google_secret_manager_secret_version' blocks
    └── variables.tf        # Remove 'default' and 'sensitive' values here
```

### Pattern 1: Secret Injection via Data Source
**What:** Using `google_secret_manager_secret_version` to fetch secrets at plan/apply time.
**Example:**
```hcl
data "google_secret_manager_secret_version" "db_password" {
  secret = "prod-db-password"
}

resource "coolify_service" "app" {
  name = "my-app"
  envs = {
    DATABASE_PASSWORD = data.google_secret_manager_secret_version.db_password.secret_data
  }
}
```

### Anti-Patterns to Avoid
- **Hardcoding Secret Versions:** Avoid hardcoding the version number; use `latest` or manage versions dynamically.
- **Storing Secrets in Git:** Never commit `.env` or `.tfvars` containing actual secrets.

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Secrets in `terraform.tfstate` | Ensure state bucket is restricted and encrypted. |
| Secrets/env vars | `terraform.tfvars` (local) | Delete after migration to GCP Secret Manager. |

## Common Pitfalls

### Pitfall 1: IAM Permissions
**What goes wrong:** Terraform runner lacks `roles/secretmanager.secretAccessor` permission.
**How to avoid:** Explicitly grant the service account or user identity the required role for specific secrets or the entire project.

## Sources

### Primary (HIGH confidence)
- [Google Cloud Secret Manager Documentation]
- [Terraform Google Provider - Secret Manager Data Source]
