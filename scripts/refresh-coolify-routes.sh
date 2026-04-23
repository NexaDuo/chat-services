#!/usr/bin/env bash
# Refresh Coolify proxy routing when FQDNs exist but domains still return 404.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-nexaduo-492818}"
ZONE="${ZONE:-us-central1-b}"
VM_NAME="${VM_NAME:-nexaduo-chat-services}"
SSH_USER="${SSH_USER:-ubuntu}"
BASE_DOMAIN="${BASE_DOMAIN:-nexaduo.com}"

check_public_not_404() {
  local host="$1"
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://${host}")"
  echo "Public ${host} -> HTTP ${code}"
  [[ "${code}" != "404" ]] || {
    echo "${host} is still returning 404 at edge." >&2
    exit 1
  }
}

echo "Refreshing Coolify proxy routes on ${VM_NAME} (${PROJECT_ID}/${ZONE}) for *.${BASE_DOMAIN}"

gcloud compute ssh "${SSH_USER}@${VM_NAME}" \
  --project "${PROJECT_ID}" \
  --zone "${ZONE}" \
  --tunnel-through-iap \
  --command "BASE_DOMAIN='${BASE_DOMAIN}' bash -s" <<'REMOTE'
set -euo pipefail

local_code_for_host() {
  local host="$1"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: ${host}" http://127.0.0.1/ || true
}

check_local_not_404() {
  local host="$1"
  local code
  code="$(local_code_for_host "${host}")"
  echo "Local Traefik ${host} -> HTTP ${code}"
  [[ "${code}" != "404" ]]
}

check_local_dify_setup() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: dify.${BASE_DOMAIN}" http://127.0.0.1/console/api/setup || true)"
  echo "Local Traefik dify.${BASE_DOMAIN}/console/api/setup -> HTTP ${code}"
  [[ "${code}" == "200" ]]
}

container_by_subname() {
  local subname="$1"
  sudo docker ps -a \
    --filter "label=coolify.service.subName=${subname}" \
    --format '{{.Names}}' | head -n 1
}

sudo docker inspect coolify >/dev/null 2>&1 || { echo "coolify container not found" >&2; exit 1; }
sudo docker inspect coolify-proxy >/dev/null 2>&1 || { echo "coolify-proxy container not found" >&2; exit 1; }

echo "Waiting for tenant containers to leave 'Created' state (up to 5 min)..."
for i in $(seq 1 60); do
  created_count=$(sudo docker ps -a \
    --filter "label=coolify.managed=true" \
    --filter "status=created" \
    --format '{{.Names}}' | wc -l)
  [[ "${created_count}" == "0" ]] && break
  sleep 5
done
if [[ "${created_count}" != "0" ]]; then
  echo "Warning: ${created_count} containers still in Created state after 5 min:" >&2
  sudo docker ps -a --filter "label=coolify.managed=true" --filter "status=created" --format '{{.Names}}' >&2
fi

echo "Running Coolify init to regenerate dynamic proxy configuration..."
sudo docker exec coolify php artisan app:init

echo "Forcing dynamic proxy rebuild on localhost server..."
sudo docker exec coolify php artisan tinker --execute '$server = App\Models\Server::find(0); if (!$server) { throw new Exception("Server id=0 not found"); } $server->setupDynamicProxyConfiguration(); echo "ok";'

echo "Restarting coolify-proxy to reload generated routes..."
sudo docker restart coolify-proxy >/dev/null
sleep 5

if ! check_local_not_404 "chat.${BASE_DOMAIN}" \
  || ! check_local_not_404 "dify.${BASE_DOMAIN}" \
  || ! check_local_not_404 "grafana.${BASE_DOMAIN}" \
  || ! check_local_not_404 "coolify.${BASE_DOMAIN}" \
  || ! check_local_dify_setup; then
  echo "Dynamic rebuild still incomplete; applying deterministic fallback routes..."

  chat_container="$(container_by_subname chatwoot-rails)"
  dify_container="$(container_by_subname dify-web)"
  dify_api_container="$(container_by_subname dify-api)"
  grafana_container="$(container_by_subname grafana)"
  [[ -n "${chat_container}" ]] || { echo "chatwoot-rails container not found" >&2; exit 1; }
  [[ -n "${dify_container}" ]] || { echo "dify-web container not found" >&2; exit 1; }
  [[ -n "${dify_api_container}" ]] || { echo "dify-api container not found" >&2; exit 1; }
  [[ -n "${grafana_container}" ]] || { echo "grafana container not found" >&2; exit 1; }

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
http:
  routers:
    nexaduo-chat:
      rule: "Host(\`chat.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      service: nexaduo-chat-svc
    nexaduo-dify:
      rule: "Host(\`dify.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      service: nexaduo-dify-svc
    nexaduo-dify-api:
      rule: "Host(\`dify.${BASE_DOMAIN}\`) && PathPrefix(\`/console/api\`)"
      priority: 200
      entryPoints: [http, https]
      service: nexaduo-dify-api-svc
    nexaduo-coolify:
      rule: "Host(\`coolify.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      service: nexaduo-coolify-svc
    nexaduo-grafana:
      rule: "Host(\`grafana.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      service: nexaduo-grafana-svc
  services:
    nexaduo-chat-svc:
      loadBalancer:
        servers:
          - url: "http://${chat_container}:3000"
    nexaduo-dify-svc:
      loadBalancer:
        servers:
          - url: "http://${dify_container}:3000"
    nexaduo-dify-api-svc:
      loadBalancer:
        servers:
          - url: "http://${dify_api_container}:5001"
    nexaduo-coolify-svc:
      loadBalancer:
        servers:
          - url: "http://coolify:8080"
    nexaduo-grafana-svc:
      loadBalancer:
        servers:
          - url: "http://${grafana_container}:3000"
EOF
  sudo install -o root -g root -m 0644 "${tmp_file}" /data/coolify/proxy/dynamic/nexaduo-routes.yaml
  rm -f "${tmp_file}"

  sudo docker restart coolify-proxy >/dev/null
  sleep 5

  check_local_not_404 "chat.${BASE_DOMAIN}" || { echo "chat route still 404 after fallback." >&2; exit 1; }
  check_local_not_404 "dify.${BASE_DOMAIN}" || { echo "dify route still 404 after fallback." >&2; exit 1; }
  check_local_not_404 "grafana.${BASE_DOMAIN}" || { echo "grafana route still 404 after fallback." >&2; exit 1; }
  check_local_not_404 "coolify.${BASE_DOMAIN}" || { echo "coolify route still 404 after fallback." >&2; exit 1; }
  check_local_dify_setup || { echo "dify setup API still failing after fallback." >&2; exit 1; }
fi
REMOTE

echo "Checking public domains..."
check_public_not_404 "chat.${BASE_DOMAIN}"
check_public_not_404 "dify.${BASE_DOMAIN}"
check_public_not_404 "grafana.${BASE_DOMAIN}"
check_public_not_404 "coolify.${BASE_DOMAIN}"
echo "Checking Dify setup API..."
setup_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://dify.${BASE_DOMAIN}/console/api/setup")"
echo "Public dify.${BASE_DOMAIN}/console/api/setup -> HTTP ${setup_code}"
[[ "${setup_code}" == "200" ]] || { echo "Dify setup API still failing at edge." >&2; exit 1; }

echo "Coolify routes refreshed and domains are no longer returning 404."
