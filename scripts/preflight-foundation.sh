#!/usr/bin/env bash
# scripts/preflight-foundation.sh
#
# Handles GCP resources that outlive a terraform destroy due to soft-delete
# retention, so the next `terraform apply` in envs/production/foundation does
# not fail with 409 "already exists".
#
# Today this covers the Workload Identity Pool + Provider for the GitHub
# publisher (30-day soft-delete in GCP). Run automatically from
# deploy-production.sh, but safe to call on its own from the foundation dir.
#
# Preconditions:
#   - cwd is infrastructure/terraform/envs/production/foundation
#   - terraform has been `init`ed
#   - gcloud is authenticated against the target project

set -euo pipefail

PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
POOL_ID="${WIF_POOL_ID:-github}"
PROVIDER_ID="${WIF_PROVIDER_ID:-nexaduo-chat-services}"

# Pre-existing global singletons shared across the prod-tier workspaces.
# When provisioning production greenfield (empty `production` workspace) these
# already exist in GCP (originally created under the `default` workspace), so a
# plain apply would 409. Import them into the current state instead.
PUBLISHER_SA_ID="${PUBLISHER_SA_ID:-gh-publisher}"
PUBLISHER_SA_EMAIL="${PUBLISHER_SA_ID}@${PROJECT_ID}.iam.gserviceaccount.com"
AR_REPO_ID="${AR_REPO_ID:-nexaduo}"
AR_LOCATION="${AR_LOCATION:-us-central1}"

pool_state() {
  gcloud iam workload-identity-pools describe "${POOL_ID}" \
    --location=global --project="${PROJECT_ID}" \
    --format='value(state)' 2>/dev/null || echo "NONE"
}

provider_state() {
  gcloud iam workload-identity-pools providers describe "${PROVIDER_ID}" \
    --workload-identity-pool="${POOL_ID}" \
    --location=global --project="${PROJECT_ID}" \
    --format='value(state)' 2>/dev/null || echo "NONE"
}

ensure_in_state() {
  local addr=$1
  local id=$2
  shift 2
  if terraform state show "${addr}" >/dev/null 2>&1; then
    return 0
  fi
  local var_file=""
  if [[ -f "../terraform.tfvars" ]]; then
    var_file="-var-file=../terraform.tfvars"
  fi
  echo "  importing ${addr}"
  terraform import -input=false ${var_file} "$@" "${addr}" "${id}"
}

POOL_STATE="$(pool_state)"
if [[ "${POOL_STATE}" == "DELETED" ]]; then
  echo "WIF pool ${POOL_ID} is soft-deleted; undeleting..."
  gcloud iam workload-identity-pools undelete "${POOL_ID}" \
    --location=global --project="${PROJECT_ID}" >/dev/null
  POOL_STATE="$(pool_state)"
fi

if [[ "${POOL_STATE}" == "ACTIVE" ]]; then
  ensure_in_state \
    "module.gh_publisher[0].google_iam_workload_identity_pool.github" \
    "projects/${PROJECT_ID}/locations/global/workloadIdentityPools/${POOL_ID}" \
    "$@"

  PROVIDER_STATE="$(provider_state)"
  if [[ "${PROVIDER_STATE}" == "DELETED" ]]; then
    echo "WIF provider ${PROVIDER_ID} is soft-deleted; undeleting..."
    gcloud iam workload-identity-pools providers undelete "${PROVIDER_ID}" \
      --workload-identity-pool="${POOL_ID}" \
      --location=global --project="${PROJECT_ID}" >/dev/null
    PROVIDER_STATE="$(provider_state)"
  fi

  if [[ "${PROVIDER_STATE}" == "ACTIVE" ]]; then
    ensure_in_state \
      "module.gh_publisher[0].google_iam_workload_identity_pool_provider.github" \
      "projects/${PROJECT_ID}/locations/global/workloadIdentityPools/${POOL_ID}/providers/${PROVIDER_ID}" \
      "$@"
  fi
fi

# Publisher service account (impersonated by GitHub Actions via WIF).
if gcloud iam service-accounts describe "${PUBLISHER_SA_EMAIL}" \
     --project="${PROJECT_ID}" >/dev/null 2>&1; then
  ensure_in_state \
    "module.gh_publisher[0].google_service_account.publisher" \
    "projects/${PROJECT_ID}/serviceAccounts/${PUBLISHER_SA_EMAIL}" \
    "$@"
fi

# Artifact Registry repository that holds the stack images.
if gcloud artifacts repositories describe "${AR_REPO_ID}" \
     --location="${AR_LOCATION}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
  ensure_in_state \
    "module.artifact_registry.google_artifact_registry_repository.main" \
    "projects/${PROJECT_ID}/locations/${AR_LOCATION}/repositories/${AR_REPO_ID}" \
    "$@"
fi
