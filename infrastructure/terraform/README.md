# NexaDuo Chat Services Infrastructure (Terraform)

This directory contains the infrastructure-as-code definition for NexaDuo Chat Services, utilizing GCP (Google Cloud Platform) and Cloudflare.

## Structure
- `/modules`: Reusable modules (VM, DNS, Cloudflare tunnel, GCS, Artifact Registry, WIF publisher).
- `/envs/production/foundation`: Base layer (VPC, VM, Firewall, DNS, Tunnel, Artifact Registry, WIF).
- `/envs/production/tenant`: Application layer (Coolify Stacks, Envs - maintained for reference).

## Prerequisites
1. **Google Cloud SDK**: Authenticated (`gcloud auth application-default login`).
2. **Terraform**: v1.0+.
3. **Cloudflare Token**: With DNS edit permissions.

## How to Execute (3-Step Provisioning)

### 1. Configure Variables
Navigate to the production directory and configure the global variables file:

```bash
cd infrastructure/terraform/envs/production
cp terraform.tfvars.example terraform.tfvars
# Edit terraform.tfvars with your real data
nano terraform.tfvars
```

### 2. Full Deploy (Recommended)

The simplest way to bring up the entire environment is to run the orchestrator, which manages the foundation via Terraform and the application via direct scripts:

```bash
./scripts/deploy-production.sh
```

The script executes:
1. `terraform apply` in `envs/production/foundation` (VM, VPC, Tunnel, DNS, backup bucket, Artifact Registry, GitHub publisher SA + Workload Identity).
2. `scripts/bootstrap-coolify.sh` (installs Coolify, generates initial API tokens, and syncs required secrets to GCP Secret Manager).
3. `scripts/build-push-images.sh` (local build + push to Artifact Registry).
4. `scripts/deploy-tenant-direct.sh` (application deploy via SCP/SSH bypassing the unstable Coolify provider).
5. `scripts/refresh-coolify-routes.sh` (optional — disable with `REFRESH_ROUTES_AFTER_DEPLOY=false`).

## How to Destroy

To completely remove the environment:

1. **Remove Applications (Manual/SSH)**: Optional, as destroying the VM clears everything.
2. **Remove Infrastructure (Foundation)**:
   ```bash
   cd infrastructure/terraform/envs/production/foundation
   terraform destroy -var-file=../terraform.tfvars
   ```

> Note: The `envs/production/tenant` layer was kept for ID reference only; active management was moved to the `deploy-tenant-direct.sh` script due to Terraform provider limitations.

## Access and Verification
- **SSH Access (via IAP)**:
  ```bash
  gcloud compute ssh nexaduo-chat-services --tunnel-through-iap
  ```
- **E2E Verification**:
  ```bash
  ./scripts/verify-v1-e2e.sh
  ```
