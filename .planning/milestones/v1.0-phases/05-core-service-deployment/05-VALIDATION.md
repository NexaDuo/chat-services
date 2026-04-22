---
phase: 5
slug: core-service-deployment
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-04-16
---

# Phase 5 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Terraform (`terraform validate`, `terraform plan`) + shell scripts + curl/HTTP checks |
| **Config file** | `infrastructure/terraform/envs/production/main.tf` |
| **Quick run command** | `terraform validate && terraform plan -detailed-exitcode` |
| **Full suite command** | `terraform validate && terraform plan && curl -sf <endpoint>/health` |
| **Estimated runtime** | ~60–120 seconds (plan includes Coolify API calls) |

---

## Sampling Rate

- **After every task commit:** Run `terraform validate`
- **After every plan wave:** Run `terraform plan -detailed-exitcode`
- **Before `/gsd-verify-work`:** Full suite + all service health checks must pass
- **Max feedback latency:** 120 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 5-01-01 | 01 | 1 | DEPLOY-01 | — | compose not exposed publicly | infra | `terraform validate` | ✅ | ⬜ pending |
| 5-01-02 | 01 | 1 | DEPLOY-01 | — | Chatwoot stack isolated lifecycle | infra | `terraform plan` | ✅ | ⬜ pending |
| 5-02-01 | 02 | 1 | DEPLOY-01 | — | Dify stack isolated from Chatwoot | infra | `terraform validate` | ✅ | ⬜ pending |
| 5-03-01 | 03 | 2 | DEPLOY-03 | — | Middleware env vars injected securely | infra | `terraform plan` | ✅ | ⬜ pending |
| 5-04-01 | 04 | 2 | DEPLOY-04 | — | Prometheus scraping all targets | manual | `curl -sf http://grafana:3000/api/health` | ✅ | ⬜ pending |
| 5-05-01 | 05 | 3 | DEPLOY-01..04 | — | E2E: all services healthy | manual | health-check script | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `scripts/health-check-all.sh` — E2E health check script for all services (Chatwoot, Dify, Middleware, Grafana)

*Existing Terraform infrastructure covers most automated verification. Shell health-check script is the only Wave 0 requirement.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Chatwoot WebSockets functional | DEPLOY-01 | Requires browser interaction | Open Chatwoot UI, send a message, verify real-time delivery |
| Dify → Middleware bridge communication | DEPLOY-03 | Requires live API call flow | Trigger Dify workflow that calls Middleware HTTP tool, verify response |
| Grafana dashboards show live metrics | DEPLOY-04 | Visual verification | Open Grafana UI, navigate to dashboards, verify non-zero metrics |
| Cross-stack internal networking | DEPLOY-01..03 | Coolify network isolation | From Middleware container, `curl chatwoot:3000/auth/sign_in` |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 120s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
