#!/usr/bin/env bash
# scripts/apply-tenant.sh
#
# Runs `terraform apply` in the tenant layer with a retry loop that works
# around the Coolify `coolify_service_envs` 409-on-create issue.
#
# Usage:
#   ./scripts/apply-tenant.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TENANT_DIR="${PROJECT_ROOT}/infrastructure/terraform/envs/production/tenant"
TFVARS="${PROJECT_ROOT}/infrastructure/terraform/envs/production/terraform.tfvars"

MAX_ATTEMPTS="${TENANT_APPLY_MAX_ATTEMPTS:-6}"
PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"

# Services were initially deployed by Coolify with the auto-populated empty
# envs (before the `coolify_service_envs` resource ran, and again after we
# wiped and re-applied them). The authoritative way to re-render containers
# with the real env values is Coolify's `/api/v1/deploy?uuid=...` endpoint,
# which rebuilds the service compose with the current envs.
redeploy_services() {
  local url token base
  url="$(gcloud secrets versions access latest --secret=coolify_url --project="${PROJECT_ID}")"
  token="$(gcloud secrets versions access latest --secret=coolify_api_token --project="${PROJECT_ID}")"
  base="${url%/api/v1}"

  echo "=== Re-deploying tenant services so containers pick up env vars ==="
  # On the first redeploy after a fresh tenant create, Coolify occasionally
  # leaves the chatwoot/nexaduo containers in "Created" state. A second
  # deploy reliably starts them, so we always fire two rounds spaced 60s.
  for round in 1 2; do
    echo "-- redeploy round ${round}/2 --"
    for svc in shared chatwoot dify nexaduo; do
      local uuid code
      uuid="$(cd "${TENANT_DIR}" && terraform state show "coolify_service.${svc}" 2>/dev/null \
        | awk '/^    uuid /{gsub(/"/,""); print $3; exit}' || true)"
      [[ -z "${uuid}" ]] && { echo "  ${svc}: not in state, skipping"; continue; }
      code="$(curl -sS -o /dev/null -w '%{http_code}' \
        -X POST -H "Authorization: Bearer ${token}" \
        "${base}/api/v1/deploy?uuid=${uuid}")"
      echo "  deploy ${svc} (${uuid}): ${code}"
    done
    if [[ "${round}" == "1" ]]; then
      sleep 60
    fi
  done
}

# Pre-deploy: Ensure permissions are correct on the VM
fix_permissions() {
  # Get VM info from tfvars
  local VM_NAME ZONE SSH_USER
  VM_NAME=$(grep "app_name" "${TFVARS}" | cut -d'"' -f2)
  ZONE=$(grep "gcp_region" "${TFVARS}" | cut -d'"' -f2)-b
  SSH_USER=$(grep "ssh_user" "${TFVARS}" | cut -d'"' -f2)

  echo "=== Fixing directory permissions on VM ($VM_NAME) ==="
  gcloud compute ssh "${SSH_USER}@${VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap \
    --command "sudo chown -R 9999:9999 /data/coolify && sudo chmod -R 775 /data/coolify"
}

cd "${TENANT_DIR}"

if [[ ! -d .terraform ]]; then
  terraform init \
    -backend-config="bucket=nexaduo-terraform-state" \
    -backend-config="prefix=terraform/tenant"
fi

LOG="$(mktemp)"
trap 'rm -f "${LOG}"' EXIT

for attempt in $(seq 1 "${MAX_ATTEMPTS}"); do
  echo "=== terraform apply (attempt ${attempt}/${MAX_ATTEMPTS}) ==="
  fix_permissions
  if terraform apply -auto-approve -var-file="${TFVARS}" 2>&1 | tee "${LOG}"; then
    echo "Tenant apply complete."
    redeploy_services
    exit 0
  fi

  if grep -qiE "409 Conflict|already exists" "${LOG}"; then
    echo "Detected 409 conflict or existing resource; cleaning auto-populated envs and retrying..."
    "${PROJECT_ROOT}/scripts/clean-service-envs.sh"
    continue
  fi

  echo "Tenant apply failed with an error that is not a known 409 conflict." >&2
  exit 1
done

echo "Tenant apply did not converge after ${MAX_ATTEMPTS} attempts." >&2
exit 1
