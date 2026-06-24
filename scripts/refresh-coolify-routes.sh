#!/usr/bin/env bash
# Refresh Coolify proxy routing when FQDNs exist but domains still return 404.
set -euo pipefail

PROJECT_ID="${PROJECT_ID:-nexaduo-492818}"
ZONE="${ZONE:-us-central1-b}"
VM_NAME="${VM_NAME:-nexaduo-chat-services}"
SSH_USER="${SSH_USER:-ubuntu}"
BASE_DOMAIN="${BASE_DOMAIN:-nexaduo.com}"
DNS_SUFFIX="${DNS_SUFFIX:-}"
# Set SKIP_GRAFANA=true to omit Grafana from route checks and from the Traefik
# fallback yaml. Useful when nexaduo-app (Grafana) is down/exited and you still
# need to recover routing for chat/dify/coolify.
SKIP_GRAFANA="${SKIP_GRAFANA:-false}"

check_public_not_404() {
  local host="$1"
  local code
  # Retry for ~90s: a service may be mid-restart (e.g. just redeployed), which
  # briefly surfaces as a 404 at the edge before routing recovers.
  for attempt in $(seq 1 18); do
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://${host}" || echo 000)"
    if [[ "${code}" != "404" ]]; then
      echo "Public ${host} -> HTTP ${code}"
      return 0
    fi
    echo "Public ${host} -> HTTP 404 (attempt ${attempt}/18, retrying in 5s)"
    sleep 5
  done
  echo "${host} is still returning 404 at edge after retries." >&2
  exit 1
}

echo "Refreshing Coolify proxy routes on ${VM_NAME} (${PROJECT_ID}/${ZONE}) for *${DNS_SUFFIX}.${BASE_DOMAIN}"

gcloud compute ssh "${SSH_USER}@${VM_NAME}" \
  --project "${PROJECT_ID}" \
  --zone "${ZONE}" \
  --tunnel-through-iap \
  --quiet \
  --command "BASE_DOMAIN='${BASE_DOMAIN}' DNS_SUFFIX='${DNS_SUFFIX}' SKIP_GRAFANA='${SKIP_GRAFANA}' bash -s" <<'REMOTE'
set -euo pipefail

local_code_for_host() {
  local host="$1"
  curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: ${host}" http://127.0.0.1/ || true
}

check_local_not_404() {
  local host="$1"
  local code
  if [[ "${host}" == "middleware${DNS_SUFFIX}.${BASE_DOMAIN}" ]]; then
    code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: ${host}" http://127.0.0.1/health || true)"
  else
    code="$(local_code_for_host "${host}")"
  fi
  echo "Local Traefik ${host} -> HTTP ${code}"
  [[ "${code}" != "404" && "${code}" != "000" ]]
}

check_local_dify_setup() {
  local code
  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 15 -H "Host: dify${DNS_SUFFIX}.${BASE_DOMAIN}" http://127.0.0.1/console/api/setup || true)"
  echo "Local Traefik dify${DNS_SUFFIX}.${BASE_DOMAIN}/console/api/setup -> HTTP ${code}"
  [[ "${code}" == "200" ]]
}

# Retry wrappers. A `docker restart coolify-proxy` leaves Traefik briefly
# unhealthy (404/502/000 for ~20-30s) before it reloads routes and backends.
# The post-write verification must tolerate that window, otherwise it fails the
# routes job on a transient 502 even though the routes (and the X-Forwarded-Proto
# CSRF-fix middleware) were written correctly. Retry for ~90s before giving up.
retry_check() {
  # usage: retry_check "<human label>" <function> [args...]
  local label="$1"; shift
  local attempt
  for attempt in $(seq 1 18); do
    if "$@"; then
      return 0
    fi
    echo "  ${label} not ready yet (attempt ${attempt}/18); retrying in 5s..."
    sleep 5
  done
  return 1
}

container_by_subname() {
  local subname="$1"
  # Try Coolify label first, then standard Docker Compose service label
  sudo docker ps -a \
    --filter "label=coolify.service.subName=${subname}" \
    --format '{{.Names}}' | head -n 1
  
  if [[ -z "$(sudo docker ps -a --filter "label=coolify.service.subName=${subname}" --format '{{.Names}}')" ]]; then
     sudo docker ps -a \
       --filter "label=com.docker.compose.service=${subname}" \
       --format '{{.Names}}' | head -n 1
  fi
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

# Always write our deterministic routes YAML. AGENTS.md prefers the deterministic
# fallback YAML over Coolify's unreliable dynamic routing for this multi-container
# stack, and -- critically -- our YAML is the only place the Chatwoot CSRF fix
# lives (the nexaduo-force-https-proto headers middleware that rewrites
# X-Forwarded-Proto to https; see the middlewares block below). Gating the write
# on "dynamic rebuild looked broken" meant a deploy where the not-404 probes
# happened to pass left Chatwoot on a route WITHOUT the middleware -> the 422
# origin/base_url-mismatch bug returned. So we force the write every deploy. The
# checks below are kept for informational logging only.
need_fallback=1
check_local_not_404 "chat${DNS_SUFFIX}.${BASE_DOMAIN}"       || true
check_local_not_404 "dify${DNS_SUFFIX}.${BASE_DOMAIN}"       || true
check_local_not_404 "coolify${DNS_SUFFIX}.${BASE_DOMAIN}"     || true
check_local_not_404 "evolution${DNS_SUFFIX}.${BASE_DOMAIN}"   || true
check_local_not_404 "middleware${DNS_SUFFIX}.${BASE_DOMAIN}"  || true
check_local_dify_setup                          || true
if [[ "${SKIP_GRAFANA}" != "true" ]]; then
  check_local_not_404 "grafana${DNS_SUFFIX}.${BASE_DOMAIN}" || true
fi

if [[ "${need_fallback}" == "1" ]]; then
  echo "Writing deterministic proxy routes (with X-Forwarded-Proto=https middleware)..."

  chat_container="$(container_by_subname chatwoot-rails)"
  dify_container="$(container_by_subname dify-web)"
  dify_api_container="$(container_by_subname dify-api)"
  evolution_container="$(container_by_subname evolution-api)"
  middleware_container="$(container_by_subname middleware)"

  [[ -n "${chat_container}" ]] || { echo "chatwoot-rails container not found" >&2; exit 1; }
  [[ -n "${dify_container}" ]] || { echo "dify-web container not found" >&2; exit 1; }
  [[ -n "${dify_api_container}" ]] || { echo "dify-api container not found" >&2; exit 1; }
  [[ -n "${evolution_container}" ]] || { echo "evolution-api container not found" >&2; exit 1; }
  [[ -n "${middleware_container}" ]] || { echo "middleware container not found" >&2; exit 1; }

  # Grafana is opt-in: skip when SKIP_GRAFANA=true or its container is missing.
  grafana_container=""
  if [[ "${SKIP_GRAFANA}" != "true" ]]; then
    grafana_container="$(container_by_subname grafana)"
    [[ -n "${grafana_container}" ]] || { echo "grafana container not found (set SKIP_GRAFANA=true to skip)" >&2; exit 1; }
  fi

  # Build the YAML in two sections (routers, services) so Grafana entries can
  # be inlined inside each section instead of producing two top-level `http:`
  # blocks (Traefik rejects that).
  grafana_router=""
  grafana_service=""
  if [[ -n "${grafana_container}" ]]; then
    grafana_router=$(cat <<EOF
    nexaduo-grafana:
      rule: "Host(\`grafana${DNS_SUFFIX}.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      service: nexaduo-grafana-svc
EOF
    )
    grafana_service=$(cat <<EOF
    nexaduo-grafana-svc:
      loadBalancer:
        servers:
          - url: "http://${grafana_container}:3000"
EOF
    )
  fi

  tmp_file="$(mktemp)"
  cat > "${tmp_file}" <<EOF
http:
  routers:
    nexaduo-chat:
      rule: "Host(\`chat${DNS_SUFFIX}.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      middlewares: [nexaduo-force-https-proto]
      service: nexaduo-chat-svc
    nexaduo-dify:
      rule: "Host(\`dify${DNS_SUFFIX}.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      middlewares: [nexaduo-force-https-proto]
      service: nexaduo-dify-svc
    nexaduo-dify-api:
      rule: "Host(\`dify${DNS_SUFFIX}.${BASE_DOMAIN}\`) && PathPrefix(\`/console/api\`)"
      priority: 200
      entryPoints: [http, https]
      middlewares: [nexaduo-force-https-proto]
      service: nexaduo-dify-api-svc
    nexaduo-coolify:
      rule: "Host(\`coolify${DNS_SUFFIX}.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      service: nexaduo-coolify-svc
    nexaduo-evolution:
      rule: "Host(\`evolution${DNS_SUFFIX}.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      middlewares: [nexaduo-force-https-proto]
      service: nexaduo-evolution-svc
    nexaduo-middleware:
      rule: "Host(\`middleware${DNS_SUFFIX}.${BASE_DOMAIN}\`)"
      entryPoints: [http, https]
      middlewares: [nexaduo-force-https-proto]
      service: nexaduo-middleware-svc
${grafana_router}
  middlewares:
    # Cloudflared (HTTPS) -> coolify-proxy:80 (this http entrypoint) -> backends.
    # Traefik's http entrypoint has no forwardedHeaders.trustedIPs/insecure, so it
    # does NOT trust cloudflared's inbound X-Forwarded-Proto and rewrites it to
    # "http". Chatwoot (Rails 7.1) then computes request.base_url = http://... and
    # its CSRF forgery_protection_origin_check rejects the browser Origin
    # (https://...) with ActionController::InvalidAuthenticityToken -> HTTP 422 on
    # every non-GET form POST (e.g. SuperAdmin::UsersController#update). We force
    # the forwarded scheme back to https here. This sets a request HEADER only --
    # it does NOT issue redirects -- so it cannot create a Cloudflare SSL redirect
    # loop (cf. AGENTS.md "Cloudflare SSL Loops"). Chatwoot keeps FORCE_SSL=false.
    nexaduo-force-https-proto:
      headers:
        customRequestHeaders:
          X-Forwarded-Proto: "https"
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
    nexaduo-evolution-svc:
      loadBalancer:
        servers:
          - url: "http://${evolution_container}:8080"
    nexaduo-middleware-svc:
      loadBalancer:
        servers:
          - url: "http://${middleware_container}:4000"
${grafana_service}
EOF
  sudo install -o root -g root -m 0644 "${tmp_file}" /data/coolify/proxy/dynamic/nexaduo-routes.yaml
  rm -f "${tmp_file}"

  sudo docker restart coolify-proxy >/dev/null
  # Give the freshly restarted proxy a head start before the (retrying) checks.
  sleep 10

  retry_check "chat route"       check_local_not_404 "chat${DNS_SUFFIX}.${BASE_DOMAIN}"       || { echo "chat route still failing after fallback." >&2; exit 1; }
  retry_check "dify route"       check_local_not_404 "dify${DNS_SUFFIX}.${BASE_DOMAIN}"       || { echo "dify route still failing after fallback." >&2; exit 1; }
  retry_check "coolify route"    check_local_not_404 "coolify${DNS_SUFFIX}.${BASE_DOMAIN}"     || { echo "coolify route still failing after fallback." >&2; exit 1; }
  retry_check "evolution route"  check_local_not_404 "evolution${DNS_SUFFIX}.${BASE_DOMAIN}"   || { echo "evolution route still failing after fallback." >&2; exit 1; }
  retry_check "middleware route" check_local_not_404 "middleware${DNS_SUFFIX}.${BASE_DOMAIN}"  || { echo "middleware route still failing after fallback." >&2; exit 1; }
  retry_check "dify setup API"   check_local_dify_setup                          || { echo "dify setup API still failing after fallback." >&2; exit 1; }
  if [[ "${SKIP_GRAFANA}" != "true" ]]; then
    retry_check "grafana route"  check_local_not_404 "grafana${DNS_SUFFIX}.${BASE_DOMAIN}" || { echo "grafana route still failing after fallback." >&2; exit 1; }
  fi
fi
REMOTE

echo "Checking public domains..."
check_public_not_404 "chat${DNS_SUFFIX}.${BASE_DOMAIN}"
check_public_not_404 "dify${DNS_SUFFIX}.${BASE_DOMAIN}"
check_public_not_404 "coolify${DNS_SUFFIX}.${BASE_DOMAIN}"
check_public_not_404 "evolution${DNS_SUFFIX}.${BASE_DOMAIN}"

echo "Checking Middleware health..."
middleware_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://middleware${DNS_SUFFIX}.${BASE_DOMAIN}/health")"
echo "Public middleware${DNS_SUFFIX}.${BASE_DOMAIN}/health -> HTTP ${middleware_code}"
[[ "${middleware_code}" == "200" ]] || { echo "Middleware health check failing at edge." >&2; exit 1; }

if [[ "${SKIP_GRAFANA}" != "true" ]]; then
  check_public_not_404 "grafana${DNS_SUFFIX}.${BASE_DOMAIN}"
fi
echo "Checking Dify setup API..."
setup_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 "https://dify${DNS_SUFFIX}.${BASE_DOMAIN}/console/api/setup")"
echo "Public dify${DNS_SUFFIX}.${BASE_DOMAIN}/console/api/setup -> HTTP ${setup_code}"
[[ "${setup_code}" == "200" ]] || { echo "Dify setup API still failing at edge." >&2; exit 1; }

echo "Coolify routes refreshed and domains are no longer returning 404."
