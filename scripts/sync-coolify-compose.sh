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
sed -i 's#\${NEXADUO_CONF_PATH}#/opt/nexaduo#g' /tmp/docker-compose.chatwoot.yml
sudo docker cp /tmp/docker-compose.chatwoot.yml coolify:/tmp/chatwoot.yml
sudo docker exec coolify sh -c 'php fix_compose.php ${SERVICES["chatwoot"]} < /tmp/chatwoot.yml'

echo "=== Syncing dify ==="
sudo docker cp /tmp/docker-compose.dify.yml coolify:/tmp/dify.yml
sudo docker exec coolify sh -c 'php fix_compose.php ${SERVICES["dify"]} < /tmp/dify.yml'

echo "=== Syncing nexaduo ==="
# Coolify's compose parser only treats a volume source as a bind mount when it
# begins with a LITERAL '/'. The repo template uses \${NEXADUO_CONF_PATH}/... so
# the local CI stack (real docker compose) works, but Coolify mangles that into
# an empty NAMED volume at parse time -> observability containers crash-loop
# ("is a directory"). Rewrite to the literal /opt/nexaduo for the Coolify-bound
# copy ONLY (the repo template + CI keep the variable). The token below is
# single-quoted in the sed so the deploy shell does not expand it (it is unset).
sed -i 's#\${NEXADUO_CONF_PATH}#/opt/nexaduo#g' /tmp/docker-compose.nexaduo.yml
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

# Assert the strict service's observability mounts rendered as BIND MOUNTS at
# /opt/nexaduo, NOT as the empty named volumes Coolify creates when a source does
# not begin with a literal '/'. `config -q` PASSES for named volumes, so it cannot
# catch this class on its own -- this string check is the dedicated guard.
assert_bind_mounts() {
  local f="/data/coolify/services/$1/docker-compose.yml"
  [ -f "${f}" ] || { echo "__nofile__"; return 0; }
  if grep -q 'nexaduo-conf-path' "${f}"; then
    echo "FOUND named-volume mounts (nexaduo-conf-path*) -- observability configs are NOT bind-mounted"
    return 0
  fi
  if ! grep -q '/opt/nexaduo/observability/' "${f}"; then
    echo "MISSING /opt/nexaduo/observability/ bind mounts in rendered compose"
    return 0
  fi
  echo ""  # ok
}

# Poll docker ps for the observability containers of the strict service: each
# must reach 'Up' and must NOT be Restarting/Created. Catches the crash-loop the
# named-volume bug produced even when `config -q` was green.
assert_obs_up() {
  local uuid="$1" names status bad
  for _ in $(seq 1 18); do
    bad=""
    for svc in loki promtail tempo prometheus otel-collector; do
      status=$(sudo docker ps -a --filter "name=^/${svc}-${uuid}$" --format '{{.Status}}' 2>/dev/null)
      case "${status}" in
        Up*) : ;;
        *) bad="${bad} ${svc}=[${status:-absent}]" ;;
      esac
    done
    [ -z "${bad}" ] && { echo ""; return 0; }
    sleep 10
  done
  echo "observability containers not healthy:${bad}"
}

# Strict service (nexaduo-app) carries the observability bind-mounts that
# triggered prior "green but inert" bugs (Coolify mangling volume specs into
# invalid or named volumes). Poll until its freshly-rendered compose validates
# (the deploy we just triggered is async, so a fixed sleep could read the
# previous, stale render).
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

# Bind-mount assertion (only meaningful once a render exists).
if [ "${rc}" -eq 0 ]; then
  bm=$(assert_bind_mounts "${STRICT}")
  if [ -n "${bm}" ] && [ "${bm}" != "__nofile__" ]; then
    echo "ERROR: ${STRICT} observability mounts are not bind mounts: ${bm}" >&2
    rc=1
  else
    echo "OK: ${STRICT} observability configs bind-mounted at /opt/nexaduo"
  fi
fi

# Container health assertion (loki/promtail/tempo/prometheus/otel-collector Up).
if [ "${rc}" -eq 0 ]; then
  up=$(assert_obs_up "${STRICT}")
  if [ -n "${up}" ]; then
    echo "ERROR: ${STRICT} ${up}" >&2
    rc=1
  else
    echo "OK: ${STRICT} observability containers are Up"
  fi
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
