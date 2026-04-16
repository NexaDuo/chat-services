---
phase: 05-core-service-deployment
plan: 04
subsystem: infra
tags: [terraform, coolify, middleware, evolution, observability, prometheus, grafana]
requires:
  - phase: 05-01
    provides: shared stack, networking bootstrap, and shared env injection
  - phase: 05-02
    provides: chatwoot stack and health probe
  - phase: 05-03
    provides: dify stack and health probe
provides:
  - Coolify-managed nexaduo stack for middleware, evolution, and observability
  - Prometheus service added to deploy/docker-compose.nexaduo.yml
  - Post-deploy probe verifying middleware/grafana/prometheus/loki readiness
affects: [phase-05-plan-05, deployment-validation, coolify-apply]
tech-stack:
  added: []
  patterns: [image-only Coolify compose deployment, cross-stack health-gated depends_on]
key-files:
  created: [.planning/phases/05-core-service-deployment/05-04-SUMMARY.md]
  modified:
    - deploy/docker-compose.nexaduo.yml
    - infrastructure/terraform/envs/production/main.tf
key-decisions:
  - "Use pre-built image env substitutions for middleware and self-healing to avoid Coolify build-context resolution failures."
  - "Keep Terraform compose/filesha path depth aligned with existing 05-01..05-03 resources (../../../../) for compatibility."
patterns-established:
  - "Nexaduo stack deployment is gated on both chatwoot and dify verification resources."
  - "Grafana provisioning dependencies (POSTGRES_USER/POSTGRES_PASSWORD) are injected in the same Coolify env resource."
requirements-completed: [DEPLOY-01, DEPLOY-03, DEPLOY-04]
duration: 5m
completed: 2026-04-16
---

# Phase 05 Plan 04: Core Service Deployment Summary

**Middleware/evolution/observability stack is now Terraform-deployed in Coolify with Prometheus included and health-gated after chatwoot+dify readiness.**

## Performance

- **Duration:** 5m
- **Started:** 2026-04-16T14:46:40Z
- **Completed:** 2026-04-16T14:51:54Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments
- Reworked `deploy/docker-compose.nexaduo.yml` for Coolify-safe image-only deployment and added Prometheus + persistent volume.
- Appended `coolify_service.nexaduo`, `coolify_service_envs.nexaduo`, and `null_resource.verify_nexaduo` in production Terraform.
- Wired dependency ordering so nexaduo deploy waits for verified chatwoot and dify stacks.

## Task Commits

1. **Task 1: Update deploy/docker-compose.nexaduo.yml — add prometheus, swap build for image tags** - `e2cfc11` (feat)
2. **Task 2: Append coolify_service.nexaduo + envs + verify probe to main.tf** - `10c52c1` (feat)

## Files Created/Modified
- `deploy/docker-compose.nexaduo.yml` - Removed `build:` blocks, added `${MIDDLEWARE_IMAGE}` and `${SELF_HEALING_IMAGE}`, added Prometheus service/volume.
- `infrastructure/terraform/envs/production/main.tf` - Added nexaduo stack resource, full env injection set, and multi-endpoint post-deploy probe.

## Decisions Made
- Maintained existing Terraform path convention (`../../../../deploy/...`) and `tolist(data.coolify_servers.main.servers)[0].uuid` access to remain compatible with 05-01..05-03 working resources.
- Included Grafana admin + Postgres interpolation envs in the nexaduo env block so datasource provisioning resolves correctly at runtime.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Corrected compose/file hash path depth in appended Terraform blocks**
- **Found during:** Task 2
- **Issue:** Plan snippet used `${path.root}/../../../deploy/docker-compose.nexaduo.yml`, which does not resolve from `infrastructure/terraform/envs/production`.
- **Fix:** Used `${path.root}/../../../../deploy/docker-compose.nexaduo.yml` (matching existing 05-01..05-03 pattern) for both `compose` and `filesha256`.
- **Files modified:** infrastructure/terraform/envs/production/main.tf
- **Verification:** `terraform fmt -check main.tf`, `terraform init -backend=false -input=false`, and `terraform validate` all passed.
- **Committed in:** `10c52c1`

---

**Total deviations:** 1 auto-fixed (1 bug)
**Impact on plan:** No scope creep; deviation was required to keep Terraform references valid and compatible with existing Phase 05 resources.

## Issues Encountered
- `docker compose` / `docker-compose` was unavailable in this execution environment; YAML validity was verified via Terraform checks plus static grep assertions already covered by task acceptance checks.

## User Setup Required
Operator must ensure `var.middleware_image` and `var.self_healing_image` point to pushed images in a registry reachable by the Coolify VM (e.g., GHCR or Docker Hub with credentials configured on host).  
`CHATWOOT_API_TOKEN` may be empty on first apply; update `terraform.tfvars` after first Chatwoot login and re-apply.

## Next Phase Readiness
- Plan 05-04 infra changes are complete and committed atomically.
- Ready for phase 05-05 end-to-end deployment verification workflow.

## Self-Check: PASSED
- FOUND: `.planning/phases/05-core-service-deployment/05-04-SUMMARY.md`
- FOUND: commit `e2cfc11`
- FOUND: commit `10c52c1`
