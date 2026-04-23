#!/usr/bin/env bash
# scripts/onboard-prod.sh
#
# Runs the Playwright-based first-run onboarding (Chatwoot + Dify admin
# creation) against the production hostnames. Credentials live in GCP
# Secret Manager (admin_email, admin_password) and are generated on the
# first run so the flow is reproducible from an empty project.
#
# Idempotent: if Chatwoot/Dify are already configured, the Playwright
# scripts detect it and exit successfully.
#
# Env overrides:
#   CHATWOOT_URL       (default: https://chat.nexaduo.com)
#   DIFY_URL           (default: https://dify.nexaduo.com)
#   GCP_PROJECT_ID     (default: nexaduo-492818)
#   DEFAULT_ADMIN_EMAIL (default: admin@nexaduo.com)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ONBOARDING_DIR="${PROJECT_ROOT}/onboarding"

PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
CHATWOOT_URL="${CHATWOOT_URL:-https://chat.nexaduo.com}"
DIFY_URL="${DIFY_URL:-https://dify.nexaduo.com}"
DEFAULT_ADMIN_EMAIL="${DEFAULT_ADMIN_EMAIL:-admin@nexaduo.com}"

# Ensure admin_email / admin_password secrets exist; create on first run.
ensure_secret_with_default() {
  local name=$1 default_value=$2
  if gcloud secrets describe "${name}" --project="${PROJECT_ID}" >/dev/null 2>&1; then
    return 0
  fi
  echo "Creating secret ${name} (first run)..."
  gcloud secrets create "${name}" --project="${PROJECT_ID}" --replication-policy=automatic >/dev/null
  echo -n "${default_value}" | gcloud secrets versions add "${name}" \
    --project="${PROJECT_ID}" --data-file=- --quiet >/dev/null
}

# Chatwoot v4 requires uppercase, lowercase, number, and special char.
generate_password() {
  local suffix
  suffix="$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')"
  echo "NexaDuo@$(date +%Y)-${suffix}"
}

ensure_secret_with_default admin_email "${DEFAULT_ADMIN_EMAIL}"
ensure_secret_with_default admin_password "$(generate_password)"

ADMIN_EMAIL="$(gcloud secrets versions access latest --secret=admin_email --project="${PROJECT_ID}")"
ADMIN_PASSWORD="$(gcloud secrets versions access latest --secret=admin_password --project="${PROJECT_ID}")"

# Install onboarding deps + Playwright Chromium on first run.
if [[ ! -d "${ONBOARDING_DIR}/node_modules" ]]; then
  echo "Installing onboarding dependencies..."
  (cd "${ONBOARDING_DIR}" && npm install --silent)
fi
if [[ ! -d "${HOME}/.cache/ms-playwright" ]] || \
   [[ -z "$(ls -A "${HOME}/.cache/ms-playwright" 2>/dev/null)" ]]; then
  echo "Installing Playwright Chromium..."
  (cd "${ONBOARDING_DIR}" && npx playwright install chromium)
fi

echo "=== Running onboarding against ${CHATWOOT_URL} + ${DIFY_URL} ==="
cd "${ONBOARDING_DIR}"
CHATWOOT_FRONTEND_URL="${CHATWOOT_URL}" \
DIFY_CONSOLE_WEB_URL="${DIFY_URL}" \
ADMIN_EMAIL="${ADMIN_EMAIL}" \
ADMIN_PASSWORD="${ADMIN_PASSWORD}" \
node initial-setup.js

echo ""
echo "Admin credentials (stored in GCP Secret Manager: admin_email, admin_password):"
echo "  Email:    ${ADMIN_EMAIL}"
echo "  Password: (fetch via: gcloud secrets versions access latest --secret=admin_password --project=${PROJECT_ID})"
