# Phase 08: Production Provisioning & Rollout

## Goal
Provision the final production infrastructure on GCP using Terraform and perform the initial service rollout and verification.

## Success Criteria
1. Production VM is provisioned and reachable.
2. Cloudflare Tunnel is operational.
3. Chatwoot, Dify, and Middleware are successfully deployed and healthy.
4. Initial tenant connectivity is verified through the edge.

## Decisions
- Use `terraform apply` with the central secrets from GCP Secret Manager.
- Verify connectivity using the existing health-check scripts.

## Reference
- ROADMAP.md Phase 8
- STATE.md Phase 8 Pending Todo
