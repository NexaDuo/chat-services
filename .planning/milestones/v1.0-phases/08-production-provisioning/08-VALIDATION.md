---
phase: 8
slug: production-provisioning
status: partial
nyquist_compliant: false
created: 2026-04-19
---

# Phase 8 — Validation Strategy

> Nyquist validation coverage for production provisioning and rollout.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | Shell validation scripts + operational command checks + UAT evidence |
| **Config file** | `validation/phase8_audit.sh` |
| **Quick run command** | `./validation/phase8_audit.sh` |
| **Full suite command** | `./validation/phase8_audit.sh && curl -sSI https://chat.nexaduo.com && curl -sSI https://dify.nexaduo.com` |
| **Estimated runtime** | ~10–20 seconds (local) + network latency |

---

## Per-Task Verification Map

| Task ID | Plan | Requirement | Test Type | Automated Command | Status |
|---------|------|-------------|-----------|-------------------|--------|
| 8-01-01 | 08-01 | VAULT-03 | automated-local | `./validation/phase8_audit.sh` (checks secret-driven flow references in scripts) | ✅ green |
| 8-01-02 | 08-01 | DEPLOY-01 | automated-local | `./validation/phase8_audit.sh` (health and route scripts exist and enforce checks) | ✅ green |
| 8-01-03 | 08-01 | ROUTE-05 | automated-local | `./validation/phase8_audit.sh` (route refresh logic and non-404 checks) | ✅ green |
| 8-01-04 | 08-01 | INFRA-01, INFRA-02, INFRA-03 | automated-prod | `cd infrastructure/terraform/envs/production && terraform output public_ip` | ⚠ manual-only runtime |
| 8-01-05 | 08-01 | ROUTE-01 | automated-prod | `gcloud compute ssh nexaduo-chat-services --tunnel-through-iap --command "sudo ./scripts/health-check-all.sh"` | ⚠ manual-only runtime |
| 8-02-01 | 08-02 | ROUTE-02, DEPLOY-02 | automated-local | `./validation/phase8_audit.sh` + `curl -sSI https://dify.nexaduo.com` | ✅ green |
| 8-02-02 | 08-02 | PROV-01 | automated-local | `./validation/phase8_audit.sh` (tenant registry includes NexaDuo Main) | ✅ green |
| 8-02-03 | 08-02 | ROUTE-03, DEPLOY-06 | automated-local | `./validation/phase8_audit.sh` (worker auth forwarding + webhook token validation) | ✅ green |
| 8-02-04 | 08-02 | ROUTE-02, ROUTE-03, DEPLOY-06 | manual-observed | `08-UAT.md` test #3 (human checkpoint) | ✅ green |

*Status: ✅ green · ❌ red · ⚠ manual-only runtime*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Terraform apply for VM/tunnel/DNS in production | INFRA-01, INFRA-02, INFRA-03 | Needs GCP credentials and live infrastructure state | Run targeted/full `terraform apply` from production env and validate outputs |
| Coolify token setup and production deployment completion | DEPLOY-01 | Requires Coolify UI access and secret manager writes | Follow Plan 08-01 Tasks 3–4 with operator credentials |
| End-to-end Chatwoot conversation through edge with tenant log evidence | ROUTE-03, DEPLOY-06 | Requires live Chatwoot login and production traffic | Execute Plan 08-02 Task 3 and confirm middleware tenant logs |

---

## Validation Audit 2026-04-19

| Metric | Count |
|--------|-------|
| Requirements mapped | 12 |
| Automated-local green | 6 |
| Automated-prod/manual-runtime | 2 |
| Manual-observed green | 1 |
| Manual-only outstanding | 3 |

---

## Validation Sign-Off

- [x] PLAN/SUMMARY/UAT artifacts mapped to verification steps
- [x] Local automated validator added (`validation/phase8_audit.sh`)
- [x] Manual-only items explicitly documented with rationale
- [ ] `nyquist_compliant: true` (blocked by production-only checks)

**Approval:** partial (automation expanded; production-only checks remain manual)
