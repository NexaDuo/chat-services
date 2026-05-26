#!/usr/bin/env bash
# scripts/sync-coolify-compose.sh

set -euo pipefail

PROJECT_ID="nexaduo-492818"
ZONE="us-central1-b"
VM_NAME="nexaduo-chat-services"
URL="$(gcloud secrets versions access latest --secret=coolify_url --project="${PROJECT_ID}")"
TOKEN="$(gcloud secrets versions access latest --secret=coolify_api_token --project="${PROJECT_ID}")"
BASE="${URL%/api/v1}"

# Mapping Service Names to Local Files and UUIDs
declare -A SERVICES=(
  ["shared"]="b19ay7as9n0lgwq1nxm39z5q"
  ["chatwoot"]="eclpweb8dog0qmg0jbok4lpt"
  ["dify"]="x13ip0okvgohmencusvy7oki"
  ["nexaduo"]="dsgwuwrdnmue9nhdkeovb6tx"
)

# Upload PHP helper
gcloud compute scp --tunnel-through-iap --project="${PROJECT_ID}" --zone="${ZONE}" scripts/fix_compose.php ubuntu@${VM_NAME}:/tmp/fix_compose.php

# Prepare for all services
gcloud compute ssh ubuntu@${VM_NAME} --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap \
  --command "sudo docker cp /tmp/fix_compose.php coolify:/var/www/html/fix_compose.php"

for name in "${!SERVICES[@]}"; do
  uuid="${SERVICES[$name]}"
  file="deploy/docker-compose.${name}.yml"
  
  echo "=== Syncing ${name} (${uuid}) ==="
  
  # Upload compose file to VM
  gcloud compute scp --tunnel-through-iap --project="${PROJECT_ID}" --zone="${ZONE}" "${file}" ubuntu@${VM_NAME}:/tmp/${name}.yml
  
  # Copy to coolify container and run fix_compose
  gcloud compute ssh ubuntu@${VM_NAME} --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap \
    --command "sudo docker cp /tmp/${name}.yml coolify:/tmp/${name}.yml && sudo docker exec coolify sh -c 'php fix_compose.php ${uuid} < /tmp/${name}.yml'"
  
  echo "Triggering Deploy via API..."
  curl -sS -X POST -H "Authorization: Bearer ${TOKEN}" "${BASE}/api/v1/deploy?uuid=${uuid}" -o /dev/null
done

echo "=== All services synced and redeploy triggered. ==="
