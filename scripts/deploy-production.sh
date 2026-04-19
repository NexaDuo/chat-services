#!/bin/bash
# scripts/deploy-production.sh
# Orchestrates the production deployment in 3 phases.

set -e

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TERRAFORM_DIR="$PROJECT_ROOT/infrastructure/terraform/envs/production"

cd "$TERRAFORM_DIR"

echo "Phase 1: Provisioning Infrastructure (VM, Tunnel, DNS, Storage)..."
terraform apply -auto-approve \
  -target=module.vm \
  -target=module.tunnel \
  -target=module.dns_chat \
  -target=module.dns_dify \
  -target=module.backup_storage

echo "Phase 2: Bootstrapping Coolify..."
"$PROJECT_ROOT/scripts/bootstrap-coolify.sh"

echo "Phase 3: Deploying Coolify Services..."
terraform apply -auto-approve

if [[ "${REFRESH_ROUTES_AFTER_DEPLOY:-true}" == "true" ]]; then
  echo "Phase 4: Refreshing Coolify routes and validating public domains..."
  "$PROJECT_ROOT/scripts/refresh-coolify-routes.sh"
fi

echo "Deployment completed successfully!"
