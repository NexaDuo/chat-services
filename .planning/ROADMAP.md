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
- [x] **Phase 09: Architectural Infrastructure Refactor** - Separate Infrastructure (Foundation) and Tenant (Applications) layers to resolve coupling and provider initialization timeouts. (Completed: 2024-04-21)

## Phase Details

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

### Phase 09: Architectural Infrastructure Refactor
**Goal**: Separate Infrastructure (Foundation) and Tenant (Applications) layers to resolve coupling and provider initialization timeouts.
**Plans**: 3 plans
- [x] .planning/phases/09-architectural-infrastructure-refactor/09-01-PLAN.md — Foundation Layer Isolation.
- [x] .planning/phases/09-architectural-infrastructure-refactor/09-02-PLAN.md — Bootstrap Script & Secret Bridging.
- [x] .planning/phases/09-architectural-infrastructure-refactor/09-03-PLAN.md — Tenant Layer Isolation & Documentation.

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
| 9. Infra Refactor | 3/3 | Complete | 2026-04-21 |

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

### Phase 999.1: Follow-up — Phase 01 planning artifacts (COMPLETED)
- [x] 01-01: Produce formal PLAN artifacts (Completed: 2026-04-21)

### Phase 999.2: Follow-up — Phase 05 verification (COMPLETED)
- [x] 05-V1: Integrated logic into scripts/verify-v1-e2e.sh (Completed: 2026-04-21)
- [x] 05-V2: Integrated logic into scripts/verify-v1-e2e.sh (Completed: 2026-04-21)
- [x] 05-V3: Integrated logic into scripts/verify-v1-e2e.sh (Completed: 2026-04-21)

### Phase 999.3: Follow-up — Phase 06 planning artifacts (COMPLETED)
- [x] 06-01: Produce formal PLAN artifacts (Completed: 2026-04-21)
