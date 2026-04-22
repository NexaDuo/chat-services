# Phase 06: Secret Management & Security Hardening

## Objective
Automate secret storage for `infrastructure/terraform/envs/production/terraform.tfvars` in GCP Secret Manager, providing a central source of truth for secrets.

## Context
- The project is 100% complete across Phase 1-5 (Foundations, Management, Edge, Provisioning, Service Deployment).
- Secrets are currently in plain-text `.tfvars` files, which are git-ignored but present on local dev environments.
- GCP infrastructure is already in use.
- Goal: Move to "automatic" secret management where Terraform fetches secrets from GCP Secret Manager, eliminating local sensitive files.

## Requirements
- **VAULT-01**: Securely store all infrastructure and application secrets in GCP Secret Manager.
- **VAULT-02**: Eliminate local `.tfvars` files for sensitive data in production.
- **VAULT-03**: Integrate the vault with Terraform for automatic secret injection.
- **VAULT-04**: Synchronize secrets to local `.env` for development parity via script.

## Constraints
- Use **GCP Secret Manager** as the central vault solution.
- No secrets should be committed to the repo.

## Decisions
- [D-06-01]: Use **GCP Secret Manager** for secret management.
- [D-06-02]: Leverage GCP IAM for access control.
- [D-06-03]: Update Terraform to use the `google` provider (data sources) to fetch secrets.
