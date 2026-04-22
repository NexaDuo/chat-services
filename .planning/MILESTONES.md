# Milestones: NexaDuo Chat Services

## v1.0 — NexaDuo Omnichannel AI Stack MVP

**Shipped:** 2026-04-19
**Phases:** 1–9
**Plans:** 20 (GSD-tracked) | **Files changed:** ~200 | **LOC:** ~18.5K TS + 850 Terraform
**Timeline:** 2026-04-08 → 2026-04-21 (14 days active development)
**Status:** ✅ CLOSED 2026-04-21

### Delivered

Production-ready multi-tenant AI-driven chat platform — from GCP infrastructure via Terraform to Cloudflare edge routing with path-based multi-tenancy, full service stack (Chatwoot, Dify, Evolution API, Middleware), and automated tenant provisioning CLI. Finalized with an isolated Foundation/Tenant architecture, GCP Secret Manager integration, repository hardening for public release, and a unified final verification suite.

### Key Accomplishments

1. **Cloudflare Worker** with Hono framework for path-based multi-tenant routing (`/slug/` → origin) and dynamic HTML asset rewriting via HTMLRewriter.
2. **Secure tenant resolution** — Middleware API with Bearer auth + 10-minute in-memory cache; `X-Tenant-ID` injected at edge.
3. **Origin hardening** — GCP firewall restricted to Cloudflare IP ranges; IAP-only SSH policy for production operators.
4. **GCP Secret Manager Integration** — Centralized all application secrets, removing reliance on `.env` files for production deployments.
5. **Repository Hardening** — Scrubbed all hardcoded secrets, pinned container images, and implemented webhook authentication for public GitHub release.
6. **Automated Provisioning & Health** — TypeScript CLI for tenant lifecycle and unified health/routing validation scripts for production smoke tests.
7. **Architectural Separation** — Decoupled infrastructure (VM/VPC) from application orchestration (Coolify services) to ensure reliable, timeout-free deployments.
8. **Final E2E Verification** — Comprehensive verification suite (`verify-v1-e2e.sh`) covering edge routing, tunnels, and service integration.

### Backlog (Completed)

- [x] INFRA-06: Coolify API automation foundation (Decoupled provider initialization).
- [x] P05 Verification Gaps: WebSocket and live Dify↔Middleware probes via edge.
- [x] Grafana/Prometheus dashboard full coverage validation.
- [x] P01/P06 Planning Artifact Consolidation.

---

## v1.1 — Coolify Orchestration & Observability Hardening

**Status:** 📅 TARGETING MAY 2026

### Key Goals

- ~~**Full Coolify API Automation (INFRA-06)**: Transition from manual UI service creation to 100% declarative Terraform-driven service provisioning.~~ **⛔ DEFERRED (2026-04-22)** — Current UI-managed model + `deploy/docker-compose.*.yml` in Git + GCP Secret Manager cover ~90% of practical need. Rationale + trigger conditions documented in `.planning/phases/10-coolify-api-automation/10-CONTEXT.md` (D-10-101). Will reopen when PROV-04, staging parity, tightened DR SLO, frequent rotation pain, or compliance requirement materializes.
- **Observability Refinement**: Complete custom Grafana dashboarding for the Self-Healing Agent and Middleware-specific metrics.
- **Tenant Onboarding Enhancement**: Streamline the provisioning CLI for one-click tenant setup (DNS + Coolify + Worker).

### Archive

- Roadmap: `.planning/milestones/v1.0-ROADMAP.md`
- Requirements: `.planning/milestones/v1.0-REQUIREMENTS.md`
- Tag: `v1.0`
