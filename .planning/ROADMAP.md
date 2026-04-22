# Roadmap: NexaDuo Chat Services

## Phases

- [x] **Phase 1: Foundation (Terraform & GCP)** - Provision core infrastructure on GCP using Infrastructure as Code. (Completed: 2025-01-24)
- [x] **Phase 2: Management & Edge Connectivity** - Setup Coolify and secure Cloudflare Tunnels for portless origin access. (Completed: 2025-01-24)
- [x] **Phase 3: Edge Logic & Path Routing** - Implement Cloudflare Workers for header injection and path-based multi-tenant routing. (Completed: 2026-04-14)
- [x] **Phase 4: Automated Provisioning** - Automate tenant lifecycle management and resource allocation. (Completed: 2026-04-14)
- [x] **Phase 5: Core Service Deployment** - Deploy Chatwoot, Dify, and Middleware in a multi-tenant configuration. (Completed: 2026-04-16)
- [x] **Phase 6: Secret Management & Security Hardening** - Move sensitive data to GCP Secret Manager for centralized and secure handling. (Completed: 2026-04-16)
- [x] **Phase 7: Repository Hardening for Public Release** - Address security audit findings before making the repo public. (Completed: 2026-04-16)
- [x] **Phase 8: Production Provisioning & Rollout** - Finalize production VM via Terraform apply and verify connectivity. (Completed: 2026-04-19)
- [x] **Phase 09: Architectural Infrastructure Refactor** - Separate Infrastructure (Foundation) and Tenant (Applications) layers. (Completed: 2024-04-21)
- [⛔] **Phase 10: Coolify API Automation** - DEFERRED (2026-04-22). Scope postponed until a trigger condition fires (see `.planning/phases/10-coolify-api-automation/10-CONTEXT.md` D-10-101).
- [ ] **Phase 11: Observability Refinement** - Complete custom Grafana dashboarding for Self-Healing Agent and Middleware.
- [ ] **Phase 12: Tenant Onboarding UX** - Streamline the provisioning CLI for one-click tenant setup.

## Phase Details

### Phase 10: Coolify API Automation
**Goal**: All platform services are provisioned and managed 100% declaratively via Terraform.
**Depends on**: Phase 09
**Requirements**: INFRA-06
**Success Criteria** (what must be TRUE):
  1. No manual service creation or configuration is required in the Coolify UI.
  2. `terraform apply` in the tenant layer creates/updates all Docker Compose services, environment variables, and storage mounts.
  3. Services automatically retrieve secrets from GCP Secret Manager via Terraform injection.
**Plans**: TBD

### Phase 11: Observability Refinement
**Goal**: Deep visibility into the Self-Healing Agent and Middleware operations via custom dashboards.
**Depends on**: Phase 10
**Requirements**: OBS-01, OBS-02
**Success Criteria** (what must be TRUE):
  1. Grafana dashboard displays Self-Healing Agent diagnosis history, LLM tokens used, and action success rates.
  2. Grafana dashboard displays Middleware request/response metrics (latency, error rates) filtered by Tenant ID.
  3. Prometheus alerts are active for Middleware service degradations and Agent process failures.
**Plans**: TBD
**UI hint**: yes

### Phase 12: Tenant Onboarding UX
**Goal**: A single CLI command performs end-to-end tenant onboarding.
**Depends on**: Phase 11
**Requirements**: PROV-04
**Success Criteria** (what must be TRUE):
  1. `npm run tenant:create` automates DNS creation, Coolify resource provisioning, and Cloudflare Worker routing updates.
  2. A new tenant is fully operational and reachable at its path (e.g., `chat.nexaduo.com/new-tenant/`) within 2 minutes of command completion.
  3. CLI provides clear progress feedback and rollback on failure.
**Plans**: TBD

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
| 10. Coolify API | 0/0 | Not started | - |
| 11. Observability | 0/0 | Not started | - |
| 12. Onboarding UX | 0/0 | Not started | - |
