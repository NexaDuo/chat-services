#!/usr/bin/env bash
# =============================================================================
# health-check-all.sh — non-destructive end-to-end probe for the live
# NexaDuo stack across all four Coolify stacks (shared, chatwoot, dify,
# nexaduo). Safe to run anytime — does NOT touch state or volumes.
#
# Exit 0 = all services healthy. Non-zero = first failing check + log tail.
# =============================================================================
set -euo pipefail

step() { echo "==> $*"; }
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

container_by_subname() {
  local subname="$1"
  docker ps -a \
    --filter "label=coolify.service.subName=${subname}" \
    --format '{{.Names}}' | head -n 1
}

require_container() {
  local subname="$1"
  local name
  name="$(container_by_subname "$subname")"
  [[ -n "$name" ]] || fail "container for subName=${subname} not found"
  echo "$name"
}

# ---------------------------------------------------------------------------
# 1. Restart-loop / unhealthy detector across all nexaduo-* containers.
# ---------------------------------------------------------------------------
step "Scanning for unhealthy or restarting Coolify-managed containers"
bad=$(docker ps --filter "label=coolify.managed=true" --format '{{.Names}} {{.Status}}' \
        | grep -Ei 'restart|unhealthy' || true)
[[ -z "$bad" ]] || { echo "$bad" >&2; fail "unhealthy/restarting containers detected"; }

# ---------------------------------------------------------------------------
# 2. Containers with explicit healthchecks must report 'healthy'.
# ---------------------------------------------------------------------------
HEALTHCHECK_SUBNAMES=(
  postgres
  redis
  chatwoot-rails
)

for subname in "${HEALTHCHECK_SUBNAMES[@]}"; do
  container="$(require_container "$subname")"
  step "Checking ${container} (${subname}) health (up to 5 min)"
  for i in $(seq 1 60); do
    status=$(docker inspect -f '{{.State.Health.Status}}' "$container" 2>/dev/null || echo "missing")
    [[ "$status" == "healthy" ]] && break
    sleep 5
  done
  [[ "$status" == "healthy" ]] || fail "${container} never became healthy (status=${status})"
done

# ---------------------------------------------------------------------------
# 3. Containers without healthchecks: must exist and be running.
# ---------------------------------------------------------------------------
RUNNING_SUBNAMES=(
  chatwoot-sidekiq
  dify-api
  dify-web
  dify-worker
  dify-sandbox
  dify-plugin-daemon
  dify-ssrf-proxy
  evolution-api
  middleware
  loki
  promtail
  grafana
  prometheus
  self-healing-agent
)

for subname in "${RUNNING_SUBNAMES[@]}"; do
  container="$(require_container "$subname")"
  step "Checking ${container} (${subname}) is running"
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "missing")
  [[ "$running" == "true" ]] || fail "${container} is not running (state=${running})"
done

# ---------------------------------------------------------------------------
# 4. HTTP endpoint probes (sampling: one per stack tier).
# ---------------------------------------------------------------------------
declare -a HTTP_PROBES=(
  "Chatwoot|http://localhost:3000/|200,301,302"
  "Dify API|http://localhost:5001/console/api/setup|200"
  "Middleware|http://localhost:4000/health|200"
  "Grafana|http://localhost:3002/login|200"
  "Prometheus|http://localhost:9090/-/healthy|200"
)

for probe in "${HTTP_PROBES[@]}"; do
  IFS="|" read -r name url expected_codes <<< "$probe"
  step "Probing ${name} ${url} (expect one of ${expected_codes}, up to 1 min)"
  for i in $(seq 1 12); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
    echo ",${expected_codes}," | grep -q ",${code}," && break
    sleep 5
  done
  echo ",${expected_codes}," | grep -q ",${code}," || fail "${name} returned ${code} (expected one of ${expected_codes}) at ${url}"
done

# Middleware /config is the Bearer-authenticated endpoint internal agents
# rely on; verify it only if HANDOFF_SHARED_SECRET is available (either
# exported or fetchable via gcloud from Secret Manager).
if [[ -z "${HANDOFF_SHARED_SECRET:-}" ]] && command -v gcloud >/dev/null 2>&1; then
  HANDOFF_SHARED_SECRET="$(gcloud secrets versions access latest \
    --secret=handoff_shared_secret \
    --project="${GCP_PROJECT_ID:-nexaduo-492818}" 2>/dev/null || true)"
fi
if [[ -n "${HANDOFF_SHARED_SECRET:-}" ]]; then
  step "Probing Middleware /config (Bearer auth)"
  code=$(curl -s -o /dev/null -w '%{http_code}' \
    -H "Authorization: Bearer ${HANDOFF_SHARED_SECRET}" \
    http://localhost:4000/config || true)
  [[ "$code" == "200" ]] || fail "Middleware /config returned ${code} (expected 200)"
else
  echo "WARN: skipping Middleware /config probe (HANDOFF_SHARED_SECRET unavailable)"
fi

# Loki is not host-published in production; probe from inside the container.
loki_container="$(require_container "loki")"
step "Probing Loki readiness inside ${loki_container} (up to 1 min)"
for i in $(seq 1 12); do
  if docker exec "$loki_container" wget -qO- http://127.0.0.1:3100/ready >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
docker exec "$loki_container" wget -qO- http://127.0.0.1:3100/ready >/dev/null 2>&1 \
  || fail "Loki readiness probe failed inside container ${loki_container}"

# ---------------------------------------------------------------------------
# 5. Cross-stack network membership: confirm at least one container per
#    stack is attached to nexaduo-network (proves cross-stack DNS works).
# ---------------------------------------------------------------------------
step "Verifying nexaduo-network membership"
members=$(docker network inspect nexaduo-network -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
for required_subname in postgres chatwoot-rails dify-api middleware prometheus; do
  required_container="$(require_container "$required_subname")"
  echo "$members" | grep -qw "$required_container" || fail "nexaduo-network missing ${required_subname} (${required_container})"
done

echo "OK all stacks healthy — shared + chatwoot + dify + nexaduo"
