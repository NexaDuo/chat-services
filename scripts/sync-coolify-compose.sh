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

# Upload PHP helper
gcloud compute scp --tunnel-through-iap --project="${PROJECT_ID}" --zone="${ZONE}" --quiet scripts/fix_compose.php ubuntu@${VM_NAME}:/tmp/fix_compose.php

# Prepare for all services
gcloud compute ssh ubuntu@${VM_NAME} --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap --quiet \
  --command "sudo docker cp /tmp/fix_compose.php coolify:/var/www/html/fix_compose.php"

for name in "${!SERVICES[@]}"; do
  uuid="${SERVICES[$name]}"
  file="deploy/docker-compose.${name}.yml"
  
  echo "=== Syncing ${name} (${uuid}) ==="
  
  # Upload compose file to VM
  gcloud compute scp --tunnel-through-iap --project="${PROJECT_ID}" --zone="${ZONE}" --quiet "${file}" ubuntu@${VM_NAME}:/tmp/${name}.yml
  
  # Copy to coolify container and run fix_compose
  gcloud compute ssh ubuntu@${VM_NAME} --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap --quiet \
    --command "sudo docker cp /tmp/${name}.yml coolify:/tmp/${name}.yml && sudo docker exec coolify sh -c 'php fix_compose.php ${uuid} < /tmp/${name}.yml'"
  
  echo "Triggering Deploy via API..."
  curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" "${BASE}/api/v1/deploy?uuid=${uuid}" -o /dev/null
done

echo "=== All services synced and redeploy triggered. ==="
