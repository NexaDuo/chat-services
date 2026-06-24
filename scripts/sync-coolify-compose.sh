#!/usr/bin/env bash
# scripts/sync-coolify-compose.sh

set -euo pipefail

ENV="${1:-production}"
PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
ZONE="${GCP_ZONE:-us-central1-b}"

if [[ "$ENV" == "production" ]]; then
  VM_NAME="nexaduo-chat-services"
else
  VM_NAME="nexaduo-chat-services-staging"
fi

echo "Fetching connection details for ${ENV} environment..."
URL="$(gcloud secrets versions access latest --secret="coolify_url_${ENV}" --project="${PROJECT_ID}")"
TOKEN="$(gcloud secrets versions access latest --secret="coolify_api_token_${ENV}" --project="${PROJECT_ID}")"
BASE="${URL%/api/v1}"

# Fetch service UUIDs dynamically from Coolify API
echo "Fetching services from Coolify API..."
services_json=$(curl -sS -H "Authorization: Bearer ${TOKEN}" "${BASE}/api/v1/services")

suffix=""
if [[ "$ENV" != "production" ]]; then
  suffix="-${ENV}"
fi

declare -A SERVICES
SERVICES["shared"]=$(echo "$services_json" | jq -r ".[] | select(.name == \"nexaduo-shared${suffix}\") | .uuid")
SERVICES["chatwoot"]=$(echo "$services_json" | jq -r ".[] | select(.name == \"nexaduo-chatwoot${suffix}\") | .uuid")
SERVICES["dify"]=$(echo "$services_json" | jq -r ".[] | select(.name == \"nexaduo-dify${suffix}\") | .uuid")
SERVICES["nexaduo"]=$(echo "$services_json" | jq -r ".[] | select(.name == \"nexaduo-app${suffix}\") | .uuid")

# Ensure all UUIDs were resolved
for svc in shared chatwoot dify nexaduo; do
  uuid="${SERVICES[$svc]}"
  if [[ -z "${uuid}" || "${uuid}" == "null" ]]; then
    echo "ERROR: Could not resolve UUID for service: nexaduo-${svc}${suffix}" >&2
    exit 1
  fi
  echo "Resolved service ${svc} -> ${uuid}"
done

# Robust SSH wrapper with retry logic
gcloud_ssh() {
  local attempt
  for attempt in $(seq 1 3); do
    if gcloud compute ssh --tunnel-through-iap --quiet "$@"; then
      return 0
    fi
    echo "gcloud compute ssh failed (attempt ${attempt}/3). Retrying in 5s..." >&2
    sleep 5
  done
  return 1
}

# Robust SCP wrapper with retry logic
gcloud_scp() {
  local attempt
  for attempt in $(seq 1 3); do
    if gcloud compute scp --tunnel-through-iap --quiet "$@"; then
      return 0
    fi
    echo "gcloud compute scp failed (attempt ${attempt}/3). Retrying in 5s..." >&2
    sleep 5
  done
  return 1
}

# Upload all files in one SCP call
echo "Uploading compose files and PHP helper to VM..."
gcloud_scp \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  scripts/fix_compose.php \
  deploy/docker-compose.shared.yml \
  deploy/docker-compose.chatwoot.yml \
  deploy/docker-compose.dify.yml \
  deploy/docker-compose.nexaduo.yml \
  ubuntu@${VM_NAME}:/tmp/

# Construct single remote execution command
remote_cmd=$(cat <<EOF
set -euo pipefail
echo "=== Copying PHP helper to Coolify ==="
sudo docker cp /tmp/fix_compose.php coolify:/var/www/html/fix_compose.php

echo "=== Syncing shared ==="
sudo docker cp /tmp/docker-compose.shared.yml coolify:/tmp/shared.yml
sudo docker exec coolify sh -c 'php fix_compose.php ${SERVICES["shared"]} < /tmp/shared.yml'

echo "=== Syncing chatwoot ==="
sudo docker cp /tmp/docker-compose.chatwoot.yml coolify:/tmp/chatwoot.yml
sudo docker exec coolify sh -c 'php fix_compose.php ${SERVICES["chatwoot"]} < /tmp/chatwoot.yml'

echo "=== Syncing dify ==="
sudo docker cp /tmp/docker-compose.dify.yml coolify:/tmp/dify.yml
sudo docker exec coolify sh -c 'php fix_compose.php ${SERVICES["dify"]} < /tmp/dify.yml'

echo "=== Syncing nexaduo ==="
sudo docker cp /tmp/docker-compose.nexaduo.yml coolify:/tmp/nexaduo.yml
sudo docker exec coolify sh -c 'php fix_compose.php ${SERVICES["nexaduo"]} < /tmp/nexaduo.yml'
EOF
)

# Execute remote command in a single SSH call
echo "Executing sync commands on VM..."
gcloud_ssh \
  ubuntu@${VM_NAME} \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --command "${remote_cmd}"

# Trigger deploys via Coolify API
echo "Triggering deploys via Coolify API..."
for svc in shared chatwoot dify nexaduo; do
  uuid="${SERVICES[$svc]}"
  echo "  deploying ${svc} (${uuid})..."
  curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" "${BASE}/api/v1/deploy?uuid=${uuid}" -o /dev/null
done

echo "=== All services synced and redeploy triggered. ==="

# --- Post-deploy guard: validate Coolify's *rendered* compose -------------------
# Coolify's compose parser does not understand bash ${VAR:-default} syntax and
# silently mangles such volume specs (e.g. "/opt/nexaduo:"), which makes the
# `docker compose up` inside the deploy fail at config validation. Because the
# deploy trigger above is fire-and-forget, that failure used to go unnoticed and
# the pipeline reported green while NO container was recreated ("green but inert").
# This guard renders the same validation Coolify runs and fails loudly instead.
echo "Verifying rendered compose for each service (catch invalid specs)..."
verify_cmd=$(cat <<'EOF'
set -uo pipefail

validate_one() {
  local dir="/data/coolify/services/$1"
  [ -f "${dir}/docker-compose.yml" ] || { echo "__nofile__"; return 0; }
  sudo docker compose -f "${dir}/docker-compose.yml" --env-file "${dir}/.env" config -q 2>&1
}

# Strict service (nexaduo-app) carries the observability bind-mounts that
# triggered the original "green but inert" bug, where Coolify mangled
# ${VAR:-default} volume specs into "/opt/nexaduo:" and every redeploy failed
# silently. Poll until its freshly-rendered compose validates (the deploy we just
# triggered is async, so a fixed sleep could read the previous, stale render).
STRICT="__STRICT__"
rc=1
for _ in $(seq 1 15); do
  sleep 10
  out=$(validate_one "${STRICT}")
  if [ -z "${out}" ]; then echo "OK: ${STRICT} rendered compose is valid"; rc=0; break; fi
  if [ "${out}" = "__nofile__" ]; then echo "...waiting for Coolify to render ${STRICT}"; continue; fi
  echo "...not valid yet for ${STRICT}: ${out}" >&2
done
if [ "${rc}" -ne 0 ]; then
  echo "ERROR: ${STRICT} rendered compose never became valid (deploy would be green-but-inert)" >&2
fi

# Other services validated once as warnings only (don't expand blast radius).
for uuid in __OTHERS__; do
  out=$(validate_one "${uuid}")
  if [ -z "${out}" ] || [ "${out}" = "__nofile__" ]; then echo "OK: ${uuid} ok/absent"; else
    echo "WARN: invalid rendered compose for ${uuid} (non-strict): ${out}" >&2
  fi
done
exit $rc
EOF
)
verify_cmd="${verify_cmd/__STRICT__/${SERVICES[nexaduo]}}"
verify_cmd="${verify_cmd/__OTHERS__/${SERVICES[shared]} ${SERVICES[chatwoot]} ${SERVICES[dify]}}"
gcloud_ssh \
  ubuntu@${VM_NAME} \
  --project="${PROJECT_ID}" \
  --zone="${ZONE}" \
  --command "${verify_cmd}"

echo "=== Rendered compose verified for all services. ==="
