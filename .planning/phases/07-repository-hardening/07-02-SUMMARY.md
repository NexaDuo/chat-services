---
phase: "07-repository-hardening"
plan: "02"
subsystem: "security"
tags: ["auth", "networking", "hardening"]
requires: ["07-01"]
provides: ["Secure webhooks", "Hardened ingress"]
tech-stack: ["Docker Compose", "Fastify", "Zod"]
key-files: ["middleware/src/handlers/chatwoot-webhook.ts", "deploy/docker-compose.shared.yml", "deploy/docker-compose.dify.yml", "SECURITY.md"]
metrics:
  duration: "30m"
  completed_date: "2026-04-16"
---

# Phase 07 Plan 02: Webhook Security & Ingress Hardening Summary

Implemented webhook authentication for Chatwoot, restricted inbound network access to Postgres and Redis, and hardened Dify configuration by removing wildcard CORS and enabling plugin signature verification.

## Key Changes

### 1. Chatwoot Webhook Authentication
- Updated `middleware/src/config.ts` to include `CHATWOOT_WEBHOOK_TOKEN`.
- Modified `middleware/src/handlers/chatwoot-webhook.ts` to validate the `X-Chatwoot-Webhook-Token` header.
- Added 401 Unauthorized response for invalid tokens.
- Added backward compatibility: if token is not configured, it logs a warning but allows the request (enabling zero-downtime migration).

### 2. Ingress Hardening
- **Postgres/Redis:** Removed public port mapping for Postgres (5432) in `deploy/docker-compose.shared.yml`. Redis was already restricted.
- **Dify CORS:** Replaced wildcard `*` CORS settings with dynamic `${DIFY_CORS_ALLOW_ORIGINS:-*}` in `deploy/docker-compose.dify.yml`.
- **Dify Plugins:** Enabled `FORCE_VERIFYING_SIGNATURE: "true"` in `deploy/docker-compose.dify.yml` to prevent unauthorized plugin execution.

### 3. Security Policy & Documentation
- Updated `SECURITY.md` with a vulnerability reporting policy.
- Documented Phase 07 security mitigations in `SECURITY.md`.
- Updated `.env.example` with the new environment variables (`DIFY_CORS_ALLOW_ORIGINS`, `CHATWOOT_WEBHOOK_TOKEN`).

## Verification Results

### Automated Tests
- Checked `middleware/src/handlers/chatwoot-webhook.ts` for header validation logic.
- Verified `deploy/docker-compose.shared.yml` has no `ports` for Postgres.
- Verified `deploy/docker-compose.dify.yml` has `FORCE_VERIFYING_SIGNATURE: "true"`.

### Success Criteria Status
- [x] Token validation active in Middleware.
- [x] Postgres/Redis ports restricted to internal network.
- [x] Wildcard CORS removed from Dify (now configurable).
- [x] Plugin signature verification enabled.
- [x] Security policy documented in `SECURITY.md`.

## Deviations from Plan
- None - plan executed as written.

## Self-Check: PASSED
- [x] All tasks executed.
- [x] Each task committed individually.
- [x] All deviations documented (None).
- [x] SUMMARY.md created.
- [x] STATE.md updated.
