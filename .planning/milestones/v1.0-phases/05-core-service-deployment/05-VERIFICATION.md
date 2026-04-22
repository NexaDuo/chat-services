---
phase: 05-core-service-deployment
verified: 2026-04-16T15:43:27Z
status: gaps_found
score: 2/5 must-haves verified
overrides_applied: 0
gaps:
  - truth: "Chatwoot is fully functional (including assets and WebSockets) under a tenant-specific path."
    status: failed
    reason: "No executed evidence of tenant-path + websocket behavior; final live checkpoint was auto-approved, not performed."
    artifacts:
      - path: "scripts/health-check-all.sh"
        issue: "Checks localhost HTTP/container health only; does not verify tenant path routing or websocket behavior."
      - path: ".planning/phases/05-core-service-deployment/05-05-SUMMARY.md"
        issue: "States human checkpoint was auto-approved due environment constraints."
    missing:
      - "Run live browser + websocket verification via Cloudflare tenant path (chat.nexaduo.com/{tenant}/)."
  - truth: "Dify is accessible and able to communicate with the Middleware bridge."
    status: failed
    reason: "Terraform wiring exists, but no live integration proof (middleware<->dify request flow) captured."
    artifacts:
      - path: "infrastructure/terraform/envs/production/main.tf"
        issue: "DIFY/CHATWOOT URLs are configured, but integration not execution-verified."
      - path: "scripts/verify-middleware-health.sh"
        issue: "Script checks middleware endpoints; not end-to-end Dify handoff flow."
    missing:
      - "Execute authenticated middleware->dify integration probe in live environment."
  - truth: "Observability dashboards (Grafana) show live metrics from all deployed services."
    status: failed
    reason: "Prometheus config only proves limited targets; no evidence of 'all deployed services' metrics in Grafana dashboards."
    artifacts:
      - path: "observability/prometheus/prometheus.yml"
        issue: "Scrape configs include prometheus, middleware, dify-api(otel); not full stack coverage."
      - path: "scripts/verify-observability.sh"
        issue: "Verifies endpoint reachability and at least one UP target, not full dashboard/service coverage."
    missing:
      - "Validate Grafana dashboards with live metrics for full required service set."
human_verification:
  - test: "Tenant-path Chatwoot UI + websocket flow"
    expected: "Under chat.nexaduo.com/{tenant}/, assets load and realtime updates function."
    why_human: "Requires live browser/websocket behavior through Cloudflare edge."
  - test: "Dify ↔ Middleware bridge flow"
    expected: "Middleware request path reaches Dify and returns successful handoff response."
    why_human: "Requires running stack + authenticated integration path."
  - test: "Grafana dashboards coverage"
    expected: "Dashboards show fresh metrics for required deployed services, not just endpoint reachability."
    why_human: "Needs live dashboard inspection and semantic metric validation."
---

# Phase 05 Verification Report

**Phase Goal:** Deploy and verify the full application stack in a multi-tenant-ready environment.  
**Status:** gaps_found  
**Re-verification:** No — initial verification

## Observable Truths

1. ✅ Terraform/Coolify deployment artifacts for shared + chatwoot + dify + nexaduo stacks exist and are wired (`main.tf`, compose files, env injection, health probes).
2. ✅ DEPLOY scripts exist, are executable (`755`), and are substantive (`health-check-all.sh`, `verify-middleware-health.sh`, `verify-observability.sh`).
3. ❌ Chatwoot tenant-path + websocket full functionality not proven (auto-approved checkpoint; no live evidence).
4. ❌ Dify↔Middleware communication not proven by executed integration evidence.
5. ❌ Grafana “live metrics from all deployed services” not proven; current checks are partial.

## Requirements Coverage

- **DEPLOY-01**: ✅ SATISFIED (Coolify/Terraform orchestration implemented).
- **DEPLOY-02**: ⚠️ PARTIAL (URL/env wiring present; tenant-path runtime behavior not validated live).
- **DEPLOY-03**: ⚠️ PARTIAL (middleware deployment/probe exists; bridge integration not live-verified).
- **DEPLOY-04**: ❌ BLOCKED/PARTIAL (observability stack deployed, but “all services live metrics in dashboards” not evidenced).

## Orphaned Requirements Note

`.planning/REQUIREMENTS.md` traceability maps **Phase 5** to `PROV-01/02/03` (not DEPLOY), while Phase 05 plans and ROADMAP use DEPLOY requirements.  
This is a documentation/traceability inconsistency that should be corrected.

## Behavioral Spot-Checks (non-destructive)

- `terraform validate` in `infrastructure/terraform/envs/production`: ✅ PASS
- `bash -n` on 3 verification scripts: ✅ PASS
- Runtime script execution in this environment:
  - `verify-middleware-health.sh`: FAIL (missing `HANDOFF_SHARED_SECRET`)
  - `verify-observability.sh`: FAIL (Grafana localhost not reachable)
  - `health-check-all.sh`: timed out (no live target stack here)

These failures confirm environment limitation, not necessarily code defect.

---
Verifier: gsd-verifier
