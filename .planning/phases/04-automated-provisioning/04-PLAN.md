# Phase 4 Plan: Automated Core Service Deployment (Coolify as Code)

## Goal
Automate the configuration and deployment of all core services (Chatwoot, Dify, Middleware, Observability) within Coolify using declarative code (Terraform).

## Objectives
- [ ] Transition manual application setup to Terraform resources.
- [ ] Deploy and verify the full application stack in a multi-tenant-ready environment.
- [ ] Centralize environment variable management for all services.
- [ ] Integrate service dependencies into the IaC flow.

## Tasks

### 1. Module Preparation
- [ ] Refactor `infrastructure/terraform/modules/coolify-management/main.tf` to support modular app configurations.
- [ ] Define variables for common settings (domain, environment, tags).

### 2. Service Definitions (Terraform)
- [ ] **Chatwoot**: Create `chatwoot.tf` utilizing `coolify_application` with the Docker Compose source from `deploy/docker-compose.chatwoot.yml`.
- [ ] **Dify**: Create `dify.tf` utilizing `coolify_application` with the Docker Compose source from `deploy/docker-compose.dify.yml`.
- [ ] **Middleware**: Create `middleware.tf` for the custom NexaDuo bridge.
- [ ] **Observability**: Create `observability.tf` for Prometheus, Grafana, and Loki.

### 3. Shared Resources
- [ ] **Network**: Define a shared Coolify network for all applications to communicate internally.
- [ ] **Database**: Provision shared Postgres/Redis instances via Terraform if not handled by individual app compose files.

### 4. Secret & Environment Management
- [ ] Create a `variables.tf` in the `coolify-management` module for all sensitive tokens.
- [ ] Implement `coolify_application_envs` for each service to ensure environment parity across environments (dev/prod).

### 5. Validation & Synchronization
- [ ] Create a validation script (or use `terraform plan`) to verify configuration consistency.
- [ ] Document the process for adding new apps or updating existing ones via code.

## Success Criteria
1.  A single `terraform apply` command can reproduce the entire Chat Services stack on a clean Coolify instance.
2.  No manual changes are required in the Coolify UI to deploy or update services.
3.  All application logs and metrics are accessible immediately after deployment.

## Dependencies
- **Phase 1**: Infrastructure baseline must exist.
- **Phase 2**: Coolify must be installed and accessible.
- **Phase 4**: Core service logic must be finalized (Docker Compose files must be stable).

## Risks
- **Provider Stability**: The `SierraJC/coolify` provider is in beta and might have breaking changes.
- **API Limits**: Frequent `terraform apply` might hit Coolify API rate limits (though unlikely for this scale).
- **Complexity**: Managing multi-container compose files via Terraform strings can be verbose; use `file()` and `templatefile()` to keep it clean.
