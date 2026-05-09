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
  ["shared"]="cptudr03mfpifug3rsdjet41"
  ["chatwoot"]="rl3esrvnj7pfww9y25j8okhy"
  ["dify"]="e2h1z9nbliudddkpuigs0igt"
  ["nexaduo"]="kh0g7bovvsmtf9riyocndet3"
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
  
  # Send compose file content via stdin to a single SSH command
  cat "${file}" | gcloud compute ssh ubuntu@${VM_NAME} --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap \
    --command "sudo docker exec -i coolify php fix_compose.php ${uuid}"
  
  echo "Triggering Deploy via API..."
  curl -sS -X POST -H "Authorization: Bearer ${token}" "${BASE}/api/v1/deploy?uuid=${uuid}" -o /dev/null
done

echo "=== All services synced and redeploy triggered. ==="
