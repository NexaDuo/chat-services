# Phase 06: Secret Management & Security Hardening - Research

**Researched:** 2026-04-16
**Domain:** Secret Management, Infrastructure-as-Code (Terraform), Private Networking (Tailscale)
**Confidence:** HIGH

## Summary

This research investigates the integration of a secret vault into a Terraform-managed stack using GCP, Cloudflare, and Tailscale. The primary goal is to eliminate sensitive data from `terraform.tfvars` files and automate secret injection. 

After comparing **Infisical**, **GCP Secret Manager**, and **HashiCorp Vault**, **Infisical** is the recommended choice due to its superior developer experience (DevEx), easy self-hosting via Coolify, and explicit support for **Terraform Ephemeral Resources** (which prevents secrets from leaking into the Terraform state file). 

Tailscale will be used to secure access by hosting the Infisical instance on a private IP address, ensuring that even with valid credentials, the vault is only reachable from within the project's Tailnet.

**Primary recommendation:** Deploy **Infisical** as a self-hosted service on Coolify, restrict its access to the Tailscale network, and upgrade Terraform to **v1.10+** to leverage `ephemeral` resources for state-level secret protection.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- [D-06-01]: Use **Infisical** for secret management.
- [D-06-02]: Deploy Infisical as a Coolify stack in a separate project or within the same project.
- [D-06-03]: Update Terraform to use the `infisical` provider to fetch all secrets.

### the agent's Discretion
- Selection of authentication method for Terraform-to-Infisical (Machine Identity recommended).
- Configuration details for Tailscale-only access.
- Strategy for secret migration from `.tfvars`.

### Deferred Ideas (OUT OF SCOPE)
- Use of SOPS (Secret Operations) for file encryption — vault is preferred.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| VAULT-01 | Securely store all infrastructure and application secrets in a self-hosted vault. | Verified Infisical self-hosting on Coolify. |
| VAULT-02 | Eliminate local `.tfvars` files for sensitive data in production. | Infisical CLI supports importing from `.env` and `.tfvars`. |
| VAULT-03 | Integrate the vault with Terraform for automatic secret injection. | Infisical Terraform provider confirmed; supports Ephemeral Resources. |
| VAULT-04 | Secure vault access via Tailscale. | Tailscale-only access via Traefik binding or Firewall (UFW) verified. |
</phase_requirements>

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Secret Storage | Infisical (Vault) | GCP (IAM) | Infisical owns the values; GCP IAM manages the identity of the runner. |
| Secret Retrieval | Terraform (Provider) | — | Terraform pulls values just-in-time for resource creation. |
| Network Isolation | Tailscale | Coolify (Traefik) | Tailscale provides the private tunnel; Traefik enforces host-level routing. |
| Access Control | Infisical (RBAC) | Machine Identity | Infisical manages who (Machine Identity) can see which secrets. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Infisical | Latest (Self-hosted) | Secret Vault | Open-source, DevEx-focused, easy self-hosting on Coolify. |
| Terraform | v1.10.0+ | IaC | Required for **Ephemeral Resources** support to keep secrets out of state. |
| Infisical Provider | v0.12+ | Terraform Plugin | Native integration for fetching and managing Infisical secrets. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| Infisical CLI | v0.32+ | Secret Migration | To push existing `.tfvars` and `.env` secrets to the vault. |
| Tailscale | v1.60+ | Private Network | To expose Infisical privately and join the Terraform runner to the network. |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Infisical | GCP Secret Manager | Native to GCP, but lacks multi-cloud portability and DevEx features like Infisical's dashboard. |
| Infisical | HashiCorp Vault | Highly secure but significantly more complex to manage and "unseal" manually. |

**Installation:**
```bash
# Install Infisical CLI for migration
curl -1sLf 'https://dl.cloudsmith.io/public/infisical/cli/setup.deb.sh' | sudo -E bash
sudo apt-get update && sudo apt-get install -y infisical

# Add Infisical provider to Terraform
# (See Code Examples below)
```

## Architecture Patterns

### System Architecture Diagram
1. **Infisical** is deployed on a Coolify host (e.g., `prod-server`).
2. **Tailscale** is installed on the same host, assigning it a Tailscale IP (e.g., `100.64.0.5`).
3. **Traefik** (via Coolify) is configured to bind to the Tailscale IP or restricted via UFW.
4. **Terraform Runner** (Local machine or CI/CD) joins the Tailnet via `tailscale up`.
5. **Terraform** authenticates to Infisical via a **Machine Identity** (Client ID + Secret).
6. **Terraform** fetches secrets just-in-time and injects them into resources (e.g., Coolify Service Envs).

### Recommended Project Structure
```
infrastructure/terraform/
├── modules/
│   └── secrets/            # (Optional) Module to abstract vault lookups
└── envs/production/
    ├── providers.tf        # Configure Infisical provider
    ├── main.tf             # Use 'ephemeral' or 'data' blocks for secrets
    └── variables.tf        # Remove 'default' and 'sensitive' values here
```

### Pattern 1: Ephemeral Secret Injection
**What:** Using Terraform 1.10+ `ephemeral` blocks to fetch secrets.
**When to use:** ALWAYS for secrets to prevent them from appearing in `terraform.tfstate`.
**Example:**
```hcl
# Source: https://infisical.com/docs/integrations/platforms/terraform
terraform {
  required_version = ">= 1.10.0"
  required_providers {
    infisical = {
      source = "infisical/infisical"
    }
  }
}

provider "infisical" {
  host = "http://infisical.your-tailnet-name.ts.net" # Tailscale MagicDNS
  auth = {
    universal = {
      client_id     = var.infisical_client_id
      client_secret = var.infisical_client_secret
    }
  }
}

ephemeral "infisical_secret" "db_password" {
  name         = "POSTGRES_PASSWORD"
  env_slug     = "prod"
  workspace_id = var.infisical_project_id
  folder_path  = "/"
}

# Use the secret without it hitting the state file
resource "coolify_service" "app" {
  name = "my-app"
  envs = {
    DATABASE_PASSWORD = ephemeral.infisical_secret.db_password.value
  }
}
```

### Anti-Patterns to Avoid
- **Using `data` sources for secrets:** While functional, `data "infisical_secrets"` stores the secret values in the state file in plain text. Use `ephemeral` resources instead.
- **Public FQDN for Vault:** Don't expose Infisical to the public internet. Use Tailscale MagicDNS or IPs.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Secret Rotation | Custom cron jobs | Infisical Secret Rotation | Handles logic, retries, and history out of the box. |
| Terraform Auth | Passing long-lived keys | Universal Auth (Machine Identity) | Client ID/Secret can be scoped and rotated easily. |
| Network Security | Custom IP Tables | Tailscale ACLs | Declarative, identity-based network security. |

## Runtime State Inventory

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | Secrets in `terraform.tfstate` | Must be purged after migrating to `ephemeral` resources. |
| Live service config | `coolify_service_envs` in Coolify SQLite | Code rename only (secrets will be updated on next apply). |
| OS-registered state | None — verified by repo audit | N/A |
| Secrets/env vars | `terraform.tfvars` (local) | Delete after migration to Infisical. |
| Build artifacts | None | N/A |

## Common Pitfalls

### Pitfall 1: State Leakage
**What goes wrong:** Secrets are fetched via `data` sources and stored in `terraform.tfstate`.
**Why it happens:** Old Terraform versions or habit of using data sources.
**How to avoid:** Use Terraform 1.10+ and the `ephemeral` block.
**Warning signs:** Secrets appear when running `strings terraform.tfstate`.

### Pitfall 2: Bootstrapping Circular Dependency
**What goes wrong:** Terraform needs the Infisical Client Secret to fetch secrets, but the secret is in Infisical.
**Why it happens:** The "First Secret" problem.
**How to avoid:** Pass `INFISICAL_CLIENT_SECRET` via environment variable to the Terraform runner (e.g., GitHub Secret or local shell export).

## Code Examples

### Migration via CLI
```bash
# 1. Login to self-hosted instance
infisical login --domain http://infisical.your-tailnet-name.ts.net

# 2. Import from existing tfvars (requires conversion to .env format)
# Note: tfvars "key = \"val\"" -> .env "KEY=VAL"
grep "=" terraform.tfvars | sed 's/ = /=/' > .tmp.env
infisical secrets set --file=.tmp.env --env prod
rm .tmp.env
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `terraform.tfvars` | External Secret Vault | Always | No secrets in git or local files. |
| `data` sources | `ephemeral` resources | Dec 2024 (TF 1.10) | Secrets no longer stored in state files. |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Current runner can upgrade to TF 1.10 | Summary | State security remains "Medium" (secrets in state) if v1.9.8 is kept. |
| A2 | Coolify host is already on Tailscale | Summary | Setup will require an extra step to install/join Tailscale. |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Terraform | Secret Injection | ✓ | 1.9.8 | Upgrade to 1.10.0+ highly recommended. |
| Tailscale | Secure Access | ✓ | 1.96.4 | — |
| Coolify | Hosting Infisical | ✓ | Latest | Manual Docker Compose deployment. |

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | bash + terraform plan |
| Config file | N/A |
| Quick run command | `terraform plan` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| VAULT-03 | Secrets fetched but not in state | Smoke | `terraform apply && strings terraform.tfstate | grep -v "..."` | ❌ Wave 0 |
| VAULT-04 | Vault unreachable from public IP | Smoke | `curl -m 5 <public-ip>:8080` (should timeout) | ❌ Wave 0 |

## Sources

### Primary (HIGH confidence)
- [infisical/terraform-provider-infisical] - Documentation for ephemeral resources.
- [Official Infisical Self-hosting Docs] - Guide for Docker/Coolify deployment.
- [HashiCorp Terraform 1.10 Release Notes] - Details on ephemeral values.

### Secondary (MEDIUM confidence)
- [Tailscale + Traefik Community Guides] - Pattern for binding to private interfaces.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH - Infisical is well-documented for this stack.
- Architecture: HIGH - Tailscale + Coolify is a proven pattern in this repo.
- Pitfalls: HIGH - State leakage is a well-known Terraform security issue.

**Research date:** 2026-04-16
**Valid until:** 2026-05-16
