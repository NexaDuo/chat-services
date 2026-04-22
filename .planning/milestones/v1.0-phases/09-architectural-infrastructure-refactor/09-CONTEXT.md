<!-- generated-by: gsd-doc-writer -->
# Phase 09: Architectural Infrastructure Refactor

## Goal
Resolve 'Connection Timeout' and 'Invalid Provider Configuration' issues by decoupling core infrastructure from application orchestration. This ensures the Coolify API is fully operational and its authentication token is available in GCP Secret Manager before the application-level Terraform provider initializes.

## Success Criteria
1. **Infrastructure Isolation**: Core GCP and Cloudflare resources (Foundation) are provisioned independently of Coolify services.
2. **Automated Bridging**: The `bootstrap-coolify.sh` script reliably installs Coolify, performs health checks for API readiness, and populates GCP Secret Manager with the required API token and endpoint URL.
3. **Dynamic Orchestration**: The Applications (formerly Tenant) layer successfully fetches its provider configuration (URL and Token) from Secret Manager and its target IP from Foundation outputs or GCP data sources.
4. **State Integrity**: Foundation and Applications layers maintain separate state files in GCS using distinct prefixes within the same bucket.
5. **Clean Architecture**: Legacy monolithic Terraform files are refactored into the new 3-step pattern, and `ARCHITECTURE.md` is updated to reflect this change.

## Decisions
- **Renaming**: The layer previously referred to as 'Tenant' is now the 'Applications' layer to better reflect its role in service orchestration.
- **3-Step Process**:
  - **Step 1: Foundation (Terraform)**: Provisions GCP VM, VPC, Storage, and Cloudflare Tunnel/DNS.
  - **Step 2: Bootstrap (Script)**: Installs Coolify on the VM, waits for API readiness, generates an API token, and saves it to GCP Secret Manager.
  - **Step 3: Applications (Terraform)**: Deploys stacks (Chatwoot, Dify, NexaDuo) using the Coolify provider.
- **State Management**: Use separate GCS bucket prefixes (`terraform/state/foundation` and `terraform/state/applications`) to ensure layer independence within the same bucket.
- **Dynamic Fetching**: The Applications layer will dynamically fetch the VM IP (from Foundation output/GCP data source) and Coolify Token (from Secret Manager) at runtime.
- **Robust Bootstrap**: `bootstrap-coolify.sh` must include explicit health checks for the Coolify API to ensure it is ready for the Applications layer.
- **Secrets as SSOT**: Continue using GCP Secret Manager as the single source of truth for all environment-specific secrets and dynamically generated tokens.

## Reference
- `.planning/phases/09-architectural-infrastructure-refactor/09-01-PLAN.md`
- `.planning/phases/09-architectural-infrastructure-refactor/09-02-PLAN.md`
- `.planning/phases/09-architectural-infrastructure-refactor/09-03-PLAN.md`
- `.planning/ROADMAP.md` (Phase 09)
