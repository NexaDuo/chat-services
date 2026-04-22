# Context: Phase 1 - Foundation (Terraform & GCP)

## Phase Goal
Establish a reproducible, cost-effective infrastructure baseline on Google Cloud Platform to support a multi-tenant chat platform.

## Architectural Decisions

### 1. Orchestration Model: Global Shared Stack
- **Decision:** A single Coolify v4 instance on a single GCP VM will orchestrate all core services (Chatwoot, Dify, Evolution API).
- **Rationale:** Minimizes infrastructure costs and operational overhead for a low-cost prototype. Avoids duplicated database/Redis overhead associated with per-tenant stacks.
- **Downstream Impact:** All tenants share the same application containers; isolation is handled at the application logic layer.

### 2. Multi-Tenancy & Isolation
- **Model:** Logical isolation within shared application instances.
- **Chatwoot:** Tenants are separated via native **Accounts** (`account_id`).
- **Dify:** Tenants are separated via native **Workspaces**.
- **Middleware:** Acts as the translation layer, mapping subdomains (from Cloudflare) to internal Chatwoot/Dify IDs using a `tenants` lookup table in Postgres.

### 3. Infrastructure Baseline
- **Compute:** GCP `e2-standard-4` instance (4 vCPUs, 16GB RAM).
- **Storage:** Persistent SSD (50-100GB) for all application data and databases.
- **Ingress:** "Portless" architecture using **Cloudflare Tunnels (Argo)**. No public ports (except SSH) will be open on the GCP VM.
- **Routing:** Path-based on unified subdomains: `chat.nexaduo.com/{tenant}/` and `dify.nexaduo.com/{tenant}`.

### 4. Security & Secrets
- **Strategy:** Shared backend secrets (e.g., `DIFY_SECRET_KEY`, `POSTGRES_PASSWORD`) for the initial prototype.
- **Trade-off:** Accepted risk for the sake of simplicity and resource efficiency. A breach of the master key would expose all tenants' credentials.
- **Management:** Secrets will be managed via `.env` files/Coolify environment variables, provisioned initially via Terraform/Cloud-init if possible.

## Constraints & Requirements
- **Cost-Efficiency:** Infrastructure spend must be minimized (target < $50/mo for the base node).
- **Traceability:** All infrastructure must be provisioned via Terraform (INFRA-01, INFRA-02, INFRA-03).
- **Portability:** The Terraform setup should allow for easy replication to a new GCP project if needed.

## Deferred / Out of Scope
- **Docker Resource Limits:** Per-container CPU/Memory limits are deferred until Phase 5 (Automated Provisioning).
- **Per-Tenant Dedicated VMs:** High-cost isolation is explicitly out of scope for this foundation phase.
- **GCP Secret Manager:** Integration with managed secret services is deferred to future refinement phases.
