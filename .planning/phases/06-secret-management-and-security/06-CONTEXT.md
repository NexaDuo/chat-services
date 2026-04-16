# Phase 06: Secret Management & Security Hardening

## Objective
Automate secret storage for `infrastructure/terraform/envs/production/terraform.tfvars` in a secure vault, leveraging Tailscale for private network access.

## Context
- The project is 100% complete across Phase 1-5 (Foundations, Management, Edge, Provisioning, Service Deployment).
- Secrets are currently in plain-text `.tfvars` files, which are git-ignored but present on local dev environments.
- Tailscale is already installed on the host infrastructure/node.
- Goal: Move to "automatic" secret management where Terraform fetches secrets from a vault (Infisical or HashiCorp Vault).

## Requirements
- **VAULT-01**: Securely store all infrastructure and application secrets in a self-hosted vault.
- **VAULT-02**: Eliminate local `.tfvars` files for sensitive data in production.
- **VAULT-03**: Integrate the vault with Terraform for automatic secret injection.
- **VAULT-04**: Secure vault access via Tailscale.

## Constraints
- Use **Infisical** as the preferred vault due to ease of self-hosting on Coolify and great Terraform provider support.
- The vault should be reachable via its Tailscale IP (private) for security.
- No secrets should be committed to the repo, even encrypted (prefer pure vault over SOPS for this phase).

## Decisions
- [D-06-01]: Use **Infisical** for secret management.
- [D-06-02]: Deploy Infisical as a Coolify stack in a separate project or within the same project.
- [D-06-03]: Update Terraform to use the `infisical` provider to fetch all secrets.
