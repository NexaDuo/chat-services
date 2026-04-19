---
phase: 08-production-provisioning
plan: "01"
subsystem: infra
tags: [terraform, coolify, gcp, cloudflare, traefik]
requires:
  - phase: 07-repository-hardening
    provides: hardened images and pinned stack baselines
provides:
  - deterministic Coolify bootstrap and deployment orchestration
  - reproducible proxy route refresh flow for production 404 recovery
  - production health checks compatible with Coolify dynamic container names
affects: [08-02, production-operations]
tech-stack:
  added: [gcloud-iap local-exec pattern, coolify route refresh script]
  patterns: [IAP-first remote operations, DB-to-proxy fallback routing]
key-files:
  created: [scripts/bootstrap-coolify.sh, scripts/deploy-production.sh, scripts/refresh-coolify-routes.sh, docs/issues/deployment-on-production.md]
  modified: [infrastructure/terraform/envs/production/main.tf, deploy/docker-compose.shared.yml, scripts/health-check-all.sh]
key-decisions:
  - "Use deterministic proxy fallback YAML generation when Coolify dynamic config refresh leaves FQDNs at HTTP 404."
  - "Resolve service/container checks by Coolify labels instead of static container names."
patterns-established:
  - "Production operator flow: terraform apply -> bootstrap coolify -> deploy services -> refresh routes -> health-check."
requirements-completed: [INFRA-01, INFRA-02, INFRA-03, ROUTE-01, ROUTE-05, DEPLOY-01, VAULT-03]
duration: 56min
completed: 2026-04-19
---

# Phase 08 Plan 01: Production VM Provisioning Summary

**Production rollout is now reproducible end-to-end with automated Coolify bootstrap, deterministic FQDN route refresh, and passing full-stack health checks on the live VM.**

## Performance

- **Duration:** 56 min
- **Started:** 2026-04-19T03:47:00Z
- **Completed:** 2026-04-19T04:43:01Z
- **Tasks:** 5
- **Files modified:** 15

## Accomplishments
- Verified required Secret Manager inventory (including Coolify token/destination secrets).
- Stabilized Terraform/Coolify deployment flow for IAP-only access and production compose constraints.
- Fixed production 404 blocker on `chat/dify/coolify.nexaduo.com` via `scripts/refresh-coolify-routes.sh` and validated public responses (`302/307`, no 404).
- Ran full remote health verification using the updated `scripts/health-check-all.sh` against production containers.

## Task Commits

1. **Task 4: Full Production Service Deployment (repo automation hardening)** - `97f3003` (feat)
2. **Task 5: Final Internal Health Check (reproducible health/routing checks)** - `51c16a2` (fix)

## Files Created/Modified
- `scripts/bootstrap-coolify.sh` - Coolify admin bootstrap/token/destination setup via IAP SSH.
- `scripts/deploy-production.sh` - phased production deployment orchestrator.
- `scripts/refresh-coolify-routes.sh` - route refresh + fallback Traefik config generation + verification.
- `scripts/health-check-all.sh` - label-based container discovery and robust endpoint probes.
- `deploy/docker-compose.*.yml` + `docker-compose.yml` - production compose compatibility fixes.
- `infrastructure/terraform/envs/production/main.tf` - deployment orchestration improvements and tunnel wiring updates.

## Decisions Made
- Added a deterministic fallback route generation path because Coolify dynamic proxy rebuild can leave FQDNs unresolved (404) despite DB FQDN entries.
- Made health checks resolve containers by `coolify.service.subName` labels to survive Coolify’s runtime suffix naming.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Coolify FQDNs remained 404 after standard proxy refresh**
- **Found during:** Task 5
- **Issue:** `chat/dify/coolify.nexaduo.com` all returned 404 while services were healthy and FQDNs existed in Coolify DB.
- **Fix:** Added fallback generation of `/data/coolify/proxy/dynamic/nexaduo-routes.yaml` and automated proxy restart/verification.
- **Files modified:** `scripts/refresh-coolify-routes.sh`, `docs/issues/deployment-on-production.md`
- **Committed in:** `51c16a2`

**2. [Rule 2 - Missing Critical] Health script could not validate production stack due static container names**
- **Found during:** Task 5
- **Issue:** Script expected `nexaduo-*` container names; production Coolify uses suffixed runtime names.
- **Fix:** Switched to label-based discovery and adjusted probes (redirect and internal Loki readiness handling).
- **Files modified:** `scripts/health-check-all.sh`
- **Committed in:** `51c16a2`

## Issues Encountered
- Chatwoot platform API path check returned 404 externally; tenant creation was handled separately in Plan 02 flow.

## User Setup Required
None for Plan 01 completion.

## Threat Flags

| Flag | File | Description |
|------|------|-------------|
| threat_flag: proxy-manual-config | scripts/refresh-coolify-routes.sh | Introduces manual dynamic Traefik route file generation path; must be controlled and audited as privileged operation. |

## Next Phase Readiness
- Edge domains are now reachable (no 404).
- Production stack health checks pass remotely.
- Ready for Plan 02 tenant-level and end-to-end conversation verification.

## Self-Check: PASSED
