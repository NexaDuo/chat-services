# Roadmap: NexaDuo Chat Services

## Phases

- [x] **Phase 1: Foundation (Terraform & GCP)** - Provision core infrastructure on GCP using Infrastructure as Code. (Completed: 2025-01-24)
- [x] **Phase 2: Management & Edge Connectivity** - Setup Coolify and secure Cloudflare Tunnels for portless origin access. (Completed: 2025-01-24)
- [x] **Phase 3: Edge Logic & Path Routing** - Implement Cloudflare Workers for header injection and path-based multi-tenant routing. (Completed: 2026-04-14)
- [x] **Phase 4: Automated Provisioning** - Automate tenant lifecycle management and resource allocation. (Completed: 2026-04-14)
- [x] **Phase 5: Core Service Deployment** - Deploy Chatwoot, Dify, and Middleware in a multi-tenant configuration. (Completed: 2026-04-16)
- [x] **Phase 6: Secret Management & Security Hardening** - Move sensitive data to GCP Secret Manager for centralized and secure handling. (Completed: 2026-04-16)
- [x] **Phase 7: Repository Hardening for Public Release** - Address security audit findings (rotate secrets, remove fallbacks, webhook auth, image pinning) before making the repo public. (Completed: 2026-04-16)
- [x] **Phase 8: Production Provisioning & Rollout** - Finalize production VM via Terraform apply, verify Cloudflare Tunnel connectivity, and perform initial tenant onboarding. (Completed: 2026-04-19)

## Phase Details

### Phase 6: Secret Management & Security Hardening
**Goal**: Centralize secrets in GCP Secret Manager.
**Plans**:
- [x] .planning/quick/20260416-harden-secret-management/PLAN.md — Migrate to GCP Secret Manager.

### Phase 7: Repository Hardening for Public Release
**Goal**: Remove all committed secrets and insecure defaults to allow for safe public GitHub release.
**Completed**: 2026-04-16
**Success Criteria** (what must be TRUE):
  1. No hardcoded secrets in .env.example, compose files, or source code. (PASSED)
  2. Webhook auth implemented for Chatwoot. (PASSED)
  3. Container images pinned to specific versions. (PASSED)
  4. Wildcard CORS removed from service configs. (PASSED)
**Plans**:
- [x] .planning/phases/07-repository-hardening/07-01-PLAN.md — Global Secret Scrubbing & Image Pinning.
- [x] .planning/phases/07-repository-hardening/07-02-PLAN.md — Webhook Security & Ingress Hardening.

### Phase 8: Production Provisioning & Rollout
**Goal**: Provision the final production infrastructure and verify end-to-end connectivity.
**Target Completion**: 2026-04-17
**Success Criteria** (what must be TRUE):
  1. `terraform apply` completes successfully without manual intervention.
  2. Cloudflare Tunnel is established and reachable via edge paths.
  3. All services (Chatwoot, Dify, Middleware) report healthy.
  4. Initial tenant connectivity is verified through the edge.
**Plans**:
- [x] .planning/phases/08-production-provisioning/08-01-PLAN.md — Production VM Provisioning and Service Verification.
- [x] .planning/phases/08-production-provisioning/08-02-PLAN.md — Edge Connectivity & Multi-tenant Verification.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 1. Foundation | 1/1 | Complete | 2025-01-24 |
| 2. Management | 1/1 | Complete | 2025-01-24 |
| 3. Edge Logic | 2/2 | Complete | 2026-04-14 |
| 4. Automated Provisioning | 3/3 | Complete | 2026-04-14 |
| 5. Core Service Deployment | 5/5 | Complete | 2026-04-16 |
| 6. Secret Management | 1/1 | Complete | 2026-04-16 |
| 7. Repository Hardening | 2/2 | Complete | 2026-04-16 |
| 8. Production Provisioning | 2/2 | Complete | 2026-04-19 |

## Traceability (Requirements)

| Requirement | Phase | Status |
|-------------|-------|--------|
| INFRA-01 | Phase 1 | Completed |
| INFRA-02 | Phase 1 | Completed |
| INFRA-03 | Phase 1 | Completed |
| INFRA-04 | Phase 2 | Completed |
| INFRA-05 | Phase 2 | Completed |
| ROUTE-01 | Phase 2 | Completed |
| ROUTE-02 | Phase 3 | Completed |
| ROUTE-03 | Phase 3 | Completed |
| ROUTE-04 | Phase 2 | Completed |
| ROUTE-05 | Phase 2 | Completed |
| DEPLOY-01 | Phase 5 | Completed |
| DEPLOY-02 | Phase 5 | Completed |
| DEPLOY-03 | Phase 5 | Completed |
| DEPLOY-04 | Phase 5 | Completed |
| DEPLOY-05 | Phase 5 | Completed |
| DEPLOY-06 | Phase 5 | Completed |
| PROV-01 | Phase 4 | Completed |
| PROV-02 | Phase 4 | Completed |
| PROV-03 | Phase 4 | Completed |
| INFRA-06 | Phase 5 | Completed |
| VAULT-01 | Phase 6 | Completed |
| VAULT-02 | Phase 6 | Completed |
| VAULT-03 | Phase 6 | Completed |
| VAULT-04 | Phase 6 | Completed |
| VAULT-05 | Phase 6 | Completed |
| HARD-01 | Phase 7 | Completed |
| HARD-02 | Phase 7 | Completed |
| HARD-03 | Phase 7 | Completed |
| HARD-04 | Phase 7 | Completed |
| HARD-05 | Phase 7 | Completed |

## Backlog

### Phase 999.1: Follow-up — Phase 01 planning artifacts incomplete (BACKLOG)

**Goal:** Consolidate formal planning artifacts for Phase 01 where discussion/context exists but no phase PLAN files were recorded.
**Source phase:** 01
**Deferred at:** 2026-04-19 during /gsd-next advancement to Phase 08
**Plans:**
- [ ] 01-01: Produce formal PLAN artifacts aligned with delivered Foundation scope (context exists, no phase PLAN.md files)

### Phase 999.2: Follow-up — Phase 05 unresolved verification failures (BACKLOG)

**Goal:** Resolve unresolved verification gaps left in Phase 05 verification report.
**Source phase:** 05
**Deferred at:** 2026-04-19 during /gsd-next advancement to Phase 08
**Plans:**
- [ ] 05-V1: Run live tenant-path + websocket verification via Cloudflare edge and record evidence
- [ ] 05-V2: Execute authenticated Middleware ↔ Dify live integration probe and record evidence
- [ ] 05-V3: Validate Grafana dashboards for required full-service coverage and record evidence

### Phase 999.3: Follow-up — Phase 06 planning artifacts incomplete (BACKLOG)

**Goal:** Consolidate formal planning artifacts for Phase 06 where context/research exists but no phase PLAN files were recorded.
**Source phase:** 06
**Deferred at:** 2026-04-19 during /gsd-next advancement to Phase 08
**Plans:**
- [ ] 06-01: Produce formal PLAN artifacts aligned with delivered secret-management hardening scope (context exists, no phase PLAN.md files)
