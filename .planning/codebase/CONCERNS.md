# Codebase Concerns

**Analysis Date:** 2026-04-14

## Tech Debt

**Phase Numbering Discrepancy:**
- Issue: Significant inconsistency between `.planning/ROADMAP.md`, `.planning/STATE.md`, and the `.planning/phases/` directory structure.
- Files: `.planning/ROADMAP.md`, `.planning/STATE.md`, `.planning/phases/`
- Impact: Confusion for contributors and automated agents when determining project progress or next steps.
- Fix approach: Audit and align all planning files to a unified numbering scheme (1-6). Ensure Phase 3 (Edge Logic) and Phase 4 (Automated Provisioning) are correctly represented as deferred or in-progress.

**Single Postgres Instance (SPOF):**
- Issue: All services (Chatwoot, Dify, Evolution, Middleware, Agent) share a single Postgres container.
- Files: `deploy/docker-compose.shared.yml`
- Impact: A failure in Postgres takes down the entire stack. Large database operations (vector indexing) impact the chat latency.
- Fix approach: Migrate to a managed service or separate instances for core components.

**No Automated Tests:**
- Issue: No unit or integration test suites for the Middleware or Self-Healing Agent.
- Files: `middleware/`, `agents/self-healing/`
- Impact: Regression risk in routing and integration logic.
- Fix approach: Implement a testing framework (Vitest) and add tests for `middleware/src/handlers/`.

## Security Considerations

**Shared Secret Auth:**
- Issue: `HANDOFF_SHARED_SECRET` is the primary auth for internal communication.
- Files: `middleware/src/handlers/handoff.ts`, `agents/self-healing/src/index.ts`
- Current mitigation: Bearer token validation.
- Recommendations: Transition to OIDC or per-service API keys.

**Public IP Exposure (Temporary):**
- Issue: GCP firewall rules allow direct access to ports 3000, 3001, 8000 for onboarding.
- Files: `infrastructure/terraform/modules/gcp-vm/main.tf`
- Current mitigation: Temporary measure during Cloudflare SSL propagation.
- Recommendations: Close these ports immediately after verification and rely solely on Cloudflare Tunnels.

## Performance Bottlenecks

**Loki Polling Interval:**
- Issue: Self-healing agent polls Loki every 5 minutes.
- Files: `agents/self-healing/src/index.ts`
- Cause: Background polling loop.
- Improvement path: Implement a push-based webhook system via Loki alerting.

## Fragile Areas

**Tenant Resolution Logic:**
- Issue: Tenant mapping depends on environment variable JSON strings or manual SQL entries.
- Files: `middleware/src/config.ts`, `middleware/src/handlers/tenant.ts`
- Why fragile: Syntax errors in mapping can crash service or misroute messages.
- Safe modification: Use a centralized configuration API or a strictly validated schema.

## Scaling Limits

**Single-Node Origin:**
- Current capacity: e2-standard-4 (16GB RAM).
- Limit: Running Chatwoot, Dify, Evolution, and Middleware on one node will eventually hit memory limits as tenant counts increase.
- Scaling path: Horizontal scaling via multi-node Docker Swarm or Kubernetes.

## Test Coverage Gaps

**Middleware Webhooks:**
- What's not tested: Core `/webhooks/chatwoot` logic.
- Files: `middleware/src/handlers/chatwoot-webhook.ts`
- Risk: Critical message routing failures.
- Priority: High.

**Terraform State:**
- What's not tested: Infrastructure state drift.
- Priority: Medium.

---

*Concerns audit: 2026-04-14*
