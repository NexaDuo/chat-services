# Phase 4 Research: Automated Core Service Deployment (Coolify as Code)

## Overview
Phase 4 aims to deploy the full application stack (Chatwoot, Dify, Middleware, Observability) while simultaneously moving their configuration into a declarative "as code" format. This ensures reproducibility, version control for infrastructure settings, and easier disaster recovery from the very first deployment.

## Options for Coolify-as-Code

### 1. Terraform (SierraJC/coolify provider)
- **Status**: Community provider, version 0.10.2.
- **Pros**: Matches the existing infrastructure stack (Terraform). Can manage projects, servers, and applications.
- **Cons**: Still in beta. Some resources (like detailed service configurations or specific destination settings) might be missing or limited.
- **Capabilities**:
  - `coolify_project`: Create/Manage projects.
  - `coolify_application`: Deploy apps using Docker Compose or Dockerfiles.
  - `coolify_application_envs`: Manage environment variables.
  - `coolify_server`: Manage destination servers.

### 2. Coolify API (v1)
- **Status**: Official API.
- **Pros**: Most comprehensive control. Anything possible in the UI is (mostly) possible via API.
- **Cons**: Requires custom scripting (bash/curl, python, etc.) instead of a declarative language like HCL.
- **Use Case**: Supplementing Terraform for features not yet in the provider.

### 3. GitOps (Built-in)
- **Status**: Core feature.
- **Pros**: Coolify natively watches Git repositories.
- **Cons**: Some "meta" settings (like domain names, SSL toggles, or project structure) still need to be defined in Coolify.

## Implementation Strategy

### A. Modularize Terraform
Existing `infrastructure/terraform/modules/coolify-management` should be expanded to include:
- `chatwoot.tf`: Configuration for Chatwoot app.
- `dify.tf`: Configuration for Dify service/app.
- `middleware.tf`: Configuration for the custom bridge.
- `observability.tf`: Configuration for Prometheus/Grafana.

### B. Handle Secrets Securely
- Environment variables should be pulled from `.env` or GCP Secret Manager and passed to the `coolify_application` resources.

### C. Automated Sync
- Use a script (or a GitHub Action) that runs `terraform apply` when configurations change.

## Key Findings
- The `SierraJC/coolify` provider is sufficient for creating the **Project** and **Applications** using the `docker_compose_raw` attribute.
- We can use the same `docker-compose.yml` files found in `deploy/` by reading them into Terraform using the `templatefile()` or `file()` functions.
- Multi-tenancy routing (managed at the Cloudflare layer) can be coordinated with Coolify by defining the appropriate internal network settings in Terraform.

## Next Steps
1. Define the exact resources needed for each core service.
2. Test the `coolify_application` resource with a complex Docker Compose setup.
3. Establish a pattern for managing "Services" (which are pre-packaged templates in Coolify) vs "Applications" (custom Docker Compose).
