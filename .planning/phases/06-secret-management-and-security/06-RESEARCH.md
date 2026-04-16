# Phase 06: Secret Management & Security Hardening Research

## Vault Options Comparison

| Feature | HashiCorp Vault | Infisical |
|---------|-----------------|-----------|
| **Ease of Use** | High complexity | High simplicity |
| **Self-Hosting** | Requires unsealing, complex backends | Simple Docker-based setup |
| **Terraform Support** | Mature, feature-rich | Strong, injection-focused |
| **Tailscale Support** | Supported | Supported |
| **UI** | Professional, complex | Modern, intuitive |
| **Licensing** | BSL (Business Source License) | MIT/Open Core (MIT) |

## Recommendation
**Infisical** is recommended for this project (NexaDuo) because:
- **Fast implementation**: Can be deployed as a Coolify stack in minutes.
- **Developer-friendly**: Great CLI and UI for managing secrets.
- **Terraform Integration**: The Terraform provider is modern and easy to use.
- **Project Stage**: The project is a small-to-medium scale setup; the operational overhead of HashiCorp Vault is not justified.

## Implementation Architecture

1. **Vault Deployment**: Deploy Infisical using a `docker-compose` on the existing VM (Coolify).
2. **Access Control**: Configure Infisical to be accessible via its Tailscale IP address (e.g., `http://100.x.y.z:8080`).
3. **Secret Migration**: Use the Infisical CLI to push local `.tfvars` to a `Production` environment in Infisical.
4. **Terraform Connection**: Update Terraform `main.tf` to fetch secrets via the `infisical` provider.
5. **Automation**: Use `infisical run -- terraform apply` for local development if needed.
