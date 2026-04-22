---
phase: 05
plan: 01
subsystem: core-service-deployment
tags: [terraform, coolify, docker, networking, secrets]
requires: []
provides: [DEPLOY-01]
affects:
  - infrastructure/terraform/envs/production/variables.tf
  - infrastructure/terraform/envs/production/terraform.tfvars.example
  - infrastructure/terraform/envs/production/main.tf
  - deploy/docker-compose.shared.yml
  - deploy/docker-compose.chatwoot.yml
  - deploy/docker-compose.dify.yml
  - deploy/docker-compose.nexaduo.yml
  - .env.example
tech_stack:
  added: [terraform-coolify-resources, external-docker-network]
  patterns: [compose-file-source-of-truth, ssh-null-resource-network-bootstrap]
key_files:
  created:
    - .planning/phases/05-core-service-deployment/05-01-SUMMARY.md
  modified:
    - infrastructure/terraform/envs/production/variables.tf
    - infrastructure/terraform/envs/production/terraform.tfvars.example
    - infrastructure/terraform/envs/production/main.tf
    - deploy/docker-compose.shared.yml
    - deploy/docker-compose.chatwoot.yml
    - deploy/docker-compose.dify.yml
    - deploy/docker-compose.nexaduo.yml
    - .env.example
decisions:
  - Added all plan-listed Coolify secret variables and placeholder tfvars entries.
  - Standardized all stack compose files to external network `nexaduo-network`.
  - Added shared-stack Coolify Terraform resources with SSH network pre-create and health probe.
metrics:
  started_at: "2026-04-16T14:05:41Z"
  completed_at: "2026-04-16T14:17:00Z"
---

# Phase 05 Plan 01: Terraform shared-stack bootstrap for Coolify deployment

Implemented Phase 5 foundation for shared networking + shared stack deployment through Terraform and compose hardening.

## What Changed

- Added 20 Terraform variables in `variables.tf` for Phase-5 stack secrets/config (including sensitive flags for passwords/keys/tokens).
- Extended `terraform.tfvars.example` with documented placeholders and generation commands for all new inputs.
- Updated network blocks in all four compose files from:
  - `name: ${COMPOSE_PROJECT_NAME:-nexaduo}-network`
  to:
  - `external: true`
  - `name: nexaduo-network`
- Replaced leaked `.env.example` value:
  - `HANDOFF_SHARED_SECRET=28369644b8f8d9a3dcfe617686c0e757`
  with:
  - `HANDOFF_SHARED_SECRET=${secret_hex_32}`
- Appended Terraform resources in `main.tf`:
  - `data.coolify_servers.main`
  - `coolify_project.main`
  - `null_resource.create_shared_network` (SSH docker network inspect/create)
  - `coolify_service.shared` (compose=file shared stack)
  - `coolify_service_envs.shared` (POSTGRES_USER/POSTGRES_PASSWORD/REDIS_PASSWORD/TZ)
  - `null_resource.verify_shared` (health polling for `nexaduo-postgres` + `nexaduo-redis`)
  - outputs `coolify_project_uuid`, `coolify_shared_service_uuid`

## Dependency Edges Added

- `coolify_service.shared` -> depends_on `null_resource.create_shared_network`
- `coolify_service_envs.shared` -> implicit dependency on `coolify_service.shared.uuid`
- `null_resource.verify_shared` -> depends_on `coolify_service.shared`, `coolify_service_envs.shared`

## Operator Note (RESEARCH Open Question 2)

Pre-existing manual-PoC Docker volume names are treated as non-blocking by phase intent; this plan does not migrate or rename existing volumes.

## Verification

- `terraform fmt -check` passed for touched `.tf` files.
- `terraform init -backend=false` + `terraform validate` passed in `infrastructure/terraform/envs/production`.
- Secret leak string removed from `.env.example`.
- `COMPOSE_PROJECT_NAME` references removed from all `deploy/docker-compose.*.yml` files.

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 3 - Blocking] Terraform CLI missing in environment**
   - Installed local Terraform binary at `/home/ubuntu-24/.local/bin/terraform` to run required verification.

2. **[Rule 1 - Bug] `data.coolify_servers.main.servers[0]` index invalid**
   - Provider exposes `servers` as a set; updated to `tolist(data.coolify_servers.main.servers)[0].uuid` for valid indexing.

3. **[Rule 1 - Bug] Shared compose file path in `file()` was one level short**
   - Updated `../../../deploy/...` to `../../../../deploy/...` for `compose` and `filesha256` so Terraform validate can resolve file paths from env root.

### Deferred Issues

- Docker Compose binary/plugin unavailable in this execution environment, so compose parse verification could not be executed here.

## Commits

- `ff6ca54` — feat(05-01): add phase-5 terraform secret variables
- `5fe556e` — fix(05-01): enforce shared external network and scrub handoff secret
- `e9545f5` — feat(05-01): add coolify shared stack terraform resources

## Self-Check: PASSED

- FOUND: `.planning/phases/05-core-service-deployment/05-01-SUMMARY.md`
- FOUND: `ff6ca54`
- FOUND: `5fe556e`
- FOUND: `e9545f5`
