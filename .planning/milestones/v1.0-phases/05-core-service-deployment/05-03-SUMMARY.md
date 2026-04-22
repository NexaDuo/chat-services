---
phase: 05-core-service-deployment
plan: 03
subsystem: terraform-production
tags: [terraform, coolify, dify, deployment]
requirements: [DEPLOY-01, DEPLOY-02]
provides: [coolify_service.dify, coolify_service_envs.dify, null_resource.verify_dify]
affects: [infrastructure/terraform/envs/production/main.tf]
decisions:
  - "Deploy Dify as an independent Coolify stack that depends on verified shared services."
  - "Inject all Dify runtime env/secrets through coolify_service_envs with is_literal on sensitive keys."
  - "Gate terraform apply success on SSH health probe requiring /console/api/setup HTTP 200."
---

# Phase 05 Plan 03: Dify Stack Terraform Summary

Implemented Dify as a separate Coolify-managed Terraform stack with dependency ordering, complete env injection, and post-deploy readiness gating.

## Changes Delivered

- Added `coolify_service.dify` using `deploy/docker-compose.dify.yml`.
- Added `coolify_service_envs.dify` with required shared + Dify keys:
  - `POSTGRES_HOST`, `POSTGRES_PORT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`
  - `REDIS_HOST`, `REDIS_PASSWORD`, `TZ`
  - `DIFY_SECRET_KEY`, `DIFY_LOG_LEVEL`, `DIFY_VECTOR_STORE`
  - `DIFY_CONSOLE_API_URL`, `DIFY_APP_API_URL`
  - `DIFY_SANDBOX_API_KEY`, `DIFY_PLUGIN_DAEMON_KEY`, `DIFY_PLUGIN_DIFY_INNER_API_KEY`
  - `DIFY_API_ENABLE_METRICS`, `INNER_API_METRICS_ENABLED`
- Added `null_resource.verify_dify` SSH probe that waits for:
  - `nexaduo-dify-api` container presence
  - HTTP `200` at `http://localhost:5001/console/api/setup`
- Added output `coolify_dify_service_uuid`.

## Dependency Ordering Enforced

- `coolify_service.dify` depends on:
  - `coolify_service.shared`
  - `coolify_service_envs.shared`
  - `null_resource.verify_shared`
- This enforces shared-before-dify ordering while keeping dify and chatwoot independent siblings (both depend only on shared).

## DEPLOY-02 Alignment

- `DIFY_CONSOLE_API_URL` is wired from `var.dify_console_api_url` (default `https://dify.nexaduo.com`).
- `DIFY_APP_API_URL` is wired from `var.dify_app_api_url` (default `https://dify.nexaduo.com`).
- These align Dify-generated URLs/CORS with Cloudflare Worker path routing on `dify.nexaduo.com/{tenant}/`.

## Security Caveat

- `FORCE_VERIFYING_SIGNATURE` remains `"false"` in `deploy/docker-compose.dify.yml` (accepted caveat from plan threat model; should be reviewed before marketplace plugin usage in strict production posture).

## Verification Evidence

- `terraform fmt -check main.tf` ✅
- `terraform init -backend=false -input=false` ✅
- `terraform validate` ✅
- Required resource/key/dependency/probe grep checks ✅

## Deviations from Plan

### Auto-fixed Issues

1. **[Rule 1 - Bug] Corrected compose file relative path depth**
   - **Found during:** Task 1 implementation
   - **Issue:** Plan snippet used `../../../deploy/...` from `infrastructure/terraform/envs/production`, which does not resolve to repository root.
   - **Fix:** Used `../../../../deploy/...` for Dify `compose` and `compose_hash` trigger, matching existing shared/chatwoot resources and keeping Terraform valid.
   - **Files modified:** `infrastructure/terraform/envs/production/main.tf`
   - **Commit:** `e35606b`

## Known Stubs

None.

## Self-Check: PASSED

- FOUND: `.planning/phases/05-core-service-deployment/05-03-SUMMARY.md`
- FOUND: commit `e35606b` in git history
