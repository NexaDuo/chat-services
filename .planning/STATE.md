# Project State: NexaDuo Chat Services

## Project Reference

**Core Value:** Low-cost, multi-tenant AI-driven chat platform leveraging Chatwoot, Dify, and Evolution API via Coolify and Cloudflare.
**Current Focus:** Coolify management and Cloudflare Tunnels.

## Current Position

**Phase:** Phase 2 (Management)
**Plan:** Management & Edge Connectivity
**Status:** In Progress
**Progress:** [||||      ] 40%

## Performance Metrics
- **Total Requirements:** 16
- **Requirement Coverage:** 100% (16/16)
- **Phase Completion:** 1/5
- **Plan Completion:** 0/0

## Accumulated Context

### Decisions
- 2025-01-24: Pivot to subdomain-based routing (`{tenant}.chat.nexaduo.com`) to avoid Chatwoot subpath breakages.
- 2025-01-24: Adopt GCP as primary hosting provider using e2-standard-4 instances for cost-efficiency.
- 2025-01-24: Orchestrate with Coolify v4 to simplify multi-container management.
- 2025-01-24: Secure ingress via Cloudflare Tunnels (Argo) for "portless" origin architecture.
- 2025-01-24: Automated Coolify installation via `metadata_startup_script` in Terraform.
- 2025-01-24: Remote state management via GCS bucket `nexaduo-terraform-state`.

### Todos
- [x] Create Terraform directory structure
- [x] Implement `gcp-vm` module (VPC, Subnet, Firewall, E2 Instance)
- [x] Implement `cloudflare-dns` module (Root & Wildcard records)
- [x] Set up `production` environment configuration
- [x] Provision infrastructure (GCP VM + DNS)
- [x] Configure GCS remote state backend
- [ ] Verify Coolify accessibility on port 8000
- [ ] Configure Cloudflare Tunnels for secure access
- [ ] Investigate Cloudflare Worker scripts for subdomain to tenant mapping.
- [ ] Research Coolify API for Phase 5 automation.

### Blockers
- None.

## Session Continuity
- **Next Step:** Verify Coolify installation and start Cloudflare Tunnel setup.
- **Focus:** Application management layer.
