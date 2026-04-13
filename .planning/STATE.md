# Project State: NexaDuo Chat Services

## Project Reference

**Core Value:** Low-cost, multi-tenant AI-driven chat platform leveraging Chatwoot, Dify, and Evolution API via Coolify and Cloudflare.
**Current Focus:** Coolify management and Cloudflare Tunnels.

## Current Position

**Phase:** Phase 4 (Core Service Deployment)
**Plan:** Full stack deployment on Coolify (Chatwoot, Dify, Evolution, Middleware)
**Status:** In Progress
**Progress:** [||||||||  ] 80%

## Performance Metrics
- **Total Requirements:** 16
- **Requirement Coverage:** 100% (16/16)
- **Phase Completion:** 3/5
- **Plan Completion:** 0/0

## Accumulated Context

### Decisions
- 2025-01-24: Pivot to subdomain-based routing (`{tenant}.chat.nexaduo.com`) to avoid Chatwoot subpath breakages.
- 2025-01-24: Adopt GCP as primary hosting provider using e2-standard-4 instances for cost-efficiency.
- 2025-01-24: Orchestrate with Coolify v4 to simplify multi-container management.
- 2025-01-24: Secure ingress via Cloudflare Tunnels (Argo) for "portless" origin architecture.
- 2025-01-24: Remote state management via GCS bucket `nexaduo-terraform-state`.
- 2025-01-24: Implement dynamic tenant mapping in Middleware via Postgres `tenants` table.
- 2025-01-24: Postpone Cloudflare Worker (Phase 3) to focus on full stack deployment (Phase 4).

### Todos
- [x] Create Terraform directory structure
- [x] Implement `gcp-vm` module (VPC, Subnet, Firewall, E2 Instance)
- [x] Implement `cloudflare-dns` module (Root & Wildcard records)
- [x] Set up `production` environment configuration
- [x] Provision infrastructure (GCP VM + DNS)
- [x] Configure GCS remote state backend
- [x] Verify Coolify accessibility and initial setup
- [ ] Deploy Shared Infrastructure (Postgres, Redis) in Coolify.
- [ ] Deploy Chatwoot (Rails, Sidekiq) in Coolify.
- [ ] Deploy Dify (API, Worker, Web, Sandbox) in Coolify.
- [ ] Deploy Middleware and Evolution API in Coolify.
- [ ] Implement Cloudflare Worker for subdomain routing (Deferred).

### Blockers
- None.

## Session Continuity
- **Next Step:** Verify Coolify installation and start Cloudflare Tunnel setup.
- **Focus:** Application management layer.
