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
