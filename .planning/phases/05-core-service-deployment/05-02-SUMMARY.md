---
phase: 05-core-service-deployment
plan: 02
subsystem: terraform-production
tags: [terraform, coolify, chatwoot, deployment]
requirements: [DEPLOY-01, DEPLOY-02]
provides: [coolify_service.chatwoot, coolify_service_envs.chatwoot, null_resource.verify_chatwoot]
affects: [infrastructure/terraform/envs/production/main.tf]
decisions:
  - "Deploy Chatwoot as an independent Coolify stack that depends on verified shared services."
  - "Inject Chatwoot runtime configuration via coolify_service_envs with literal handling for secrets."
  - "Gate terraform apply success on SSH health probe (container health + HTTP 200 on /)."
---

# Phase 05 Plan 02: Chatwoot Stack Terraform Summary

Implemented Chatwoot as a separate Coolify-managed Terraform stack with ordered deployment, env injection, and post-deploy health gating.

## Changes Delivered

- Added `coolify_service.chatwoot` using `deploy/docker-compose.chatwoot.yml`.
- Added `coolify_service_envs.chatwoot` with all required keys:
  - `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
  - `REDIS_PASSWORD`, `TZ`
  - `CHATWOOT_SECRET_KEY_BASE`, `CHATWOOT_FRONTEND_URL`
  - `CHATWOOT_INSTALLATION_NAME`, `CHATWOOT_DEFAULT_LOCALE`
  - `CHATWOOT_ENABLE_ACCOUNT_SIGNUP`, `CHATWOOT_FORCE_SSL`
- Added `null_resource.verify_chatwoot` SSH probe that waits for:
  - `nexaduo-chatwoot-rails` Docker health status `healthy`
  - HTTP `200` at `http://localhost:3000/`
- Added output `coolify_chatwoot_service_uuid`.

## Dependency Ordering Enforced

- `coolify_service.chatwoot` depends on:
  - `coolify_service.shared`
  - `coolify_service_envs.shared`
  - `null_resource.verify_shared`
- `null_resource.verify_chatwoot` depends on:
  - `coolify_service.chatwoot`
  - `coolify_service_envs.chatwoot`

## DEPLOY-02 Alignment

- `CHATWOOT_FRONTEND_URL` is wired from `var.chatwoot_frontend_url` (default `https://chat.nexaduo.com`), matching the Cloudflare Worker path-based tenant routing design.

## Operator Caveats

- `verify_chatwoot.triggers.compose_hash` uses `filesha256(...)` on `deploy/docker-compose.chatwoot.yml`; compose file changes will force health verification on re-apply.

## Verification Evidence

- `terraform fmt -check main.tf` ✅
- `terraform init -backend=false -input=false` ✅
- `terraform validate` ✅
- Required resource and key grep checks ✅

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 1 - Bug] Corrected compose file relative path depth**
   - **Found during:** Task 1 implementation
   - **Issue:** Plan snippet used `../../../deploy/...` from `infrastructure/terraform/envs/production`, which resolves to a non-existent path.
   - **Fix:** Used `../../../../deploy/...` for both Chatwoot `compose` and `compose_hash` trigger to keep Terraform valid and idempotent.
   - **Files modified:** `infrastructure/terraform/envs/production/main.tf`
   - **Commit:** `0dd0ee5`

## Known Stubs

None.

## Self-Check: PASSED

- FOUND: `.planning/phases/05-core-service-deployment/05-02-SUMMARY.md`
- FOUND: commit `0dd0ee5` in git history
