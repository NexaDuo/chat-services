#!/usr/bin/env bash
# scripts/deploy-production.sh
#
# Orchestrates the full 3-step production deploy:
#   Step 1 (Foundation) — terraform apply in envs/production/foundation
#   Step 2 (Bootstrap)  — bootstrap-coolify.sh (installs Coolify, syncs secrets)
#   Step 3 (Tenant)     — apply-tenant.sh (terraform apply with 409 retry loop)
#
# Usage:
#   ./scripts/deploy-production.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PROD_DIR="${PROJECT_ROOT}/infrastructure/terraform/envs/production"
TFVARS="${PROD_DIR}/terraform.tfvars"

echo "=== Step 1/3: Foundation (VM, VPC, Tunnel, DNS) ==="
cd "${PROD_DIR}/foundation"
if [[ ! -d .terraform ]]; then
  terraform init \
    -backend-config="bucket=nexaduo-terraform-state" \
    -backend-config="prefix=terraform/foundation"
fi

"${PROJECT_ROOT}/scripts/preflight-foundation.sh" -var-file="${TFVARS}"

terraform apply -auto-approve -var-file="${TFVARS}"

echo "=== Step 2/3: Bootstrap Coolify ==="
"${PROJECT_ROOT}/scripts/bootstrap-coolify.sh"

if [[ "${SKIP_IMAGE_BUILD:-false}" != "true" ]]; then
  echo "=== Step 2b/3: Build & push images to Artifact Registry ==="
  "${PROJECT_ROOT}/scripts/build-push-images.sh"
else
  echo "=== Step 2b/3: Skipping image build (SKIP_IMAGE_BUILD=true) ==="
fi

echo "=== Step 3/3: Tenant (Direct scripted deployment) ==="
"${PROJECT_ROOT}/scripts/deploy-tenant-direct.sh"

if [[ "${REFRESH_ROUTES_AFTER_DEPLOY:-true}" == "true" ]]; then
  echo "=== Post-deploy: Refresh Coolify routes ==="
  "${PROJECT_ROOT}/scripts/refresh-coolify-routes.sh"
fi

if [[ "${SKIP_ONBOARDING:-false}" != "true" ]]; then
  echo "=== Step 4/4: Onboard Chatwoot + Dify (create initial admins) ==="
  "${PROJECT_ROOT}/scripts/onboard-prod.sh"
else
  echo "=== Step 4/4: Skipping onboarding (SKIP_ONBOARDING=true) ==="
fi

echo "Deployment completed successfully."
