#!/usr/bin/env bash
# =============================================================================
# health-check-all.sh — non-destructive end-to-end probe for the live
# NexaDuo stack across all four Coolify stacks (shared, chatwoot, dify,
# nexaduo). Safe to run anytime — does NOT touch state or volumes.
#
# Exit 0 = all services healthy. Non-zero = first failing check + log tail.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$(mktemp -d)"
trap 'echo "Logs retained at: $LOG_DIR"' EXIT

step() { echo "==> $*"; }
fail() {
  echo "FAIL: $1" >&2
  if [[ -n "${2:-}" && -f "$2" ]]; then
    echo "---- last 60 lines of $2 ----" >&2
    tail -60 "$2" >&2
  fi
  exit 1
}

# ---------------------------------------------------------------------------
# 1. Restart-loop / unhealthy detector across all nexaduo-* containers.
# ---------------------------------------------------------------------------
step "Scanning for unhealthy or restarting nexaduo-* containers"
bad=$(docker ps --filter "name=nexaduo-" --format '{{.Names}} {{.Status}}' \
        | grep -Ei 'restart|unhealthy' || true)
[[ -z "$bad" ]] || { echo "$bad" >&2; fail "unhealthy/restarting containers detected"; }

# ---------------------------------------------------------------------------
# 2. Containers with explicit healthchecks must report 'healthy'.
# ---------------------------------------------------------------------------
HEALTHCHECK_CONTAINERS=(
  nexaduo-postgres
  nexaduo-redis
  nexaduo-chatwoot-rails
)

for container in "${HEALTHCHECK_CONTAINERS[@]}"; do
  step "Checking ${container} health (up to 5 min)"
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
RUNNING_CONTAINERS=(
  nexaduo-chatwoot-sidekiq
  nexaduo-dify-api
  nexaduo-dify-web
  nexaduo-dify-worker
  nexaduo-dify-sandbox
  nexaduo-dify-plugin-daemon
  nexaduo-dify-ssrf-proxy
  nexaduo-evolution-api
  nexaduo-middleware
  nexaduo-loki
  nexaduo-promtail
  nexaduo-grafana
  nexaduo-prometheus
  nexaduo-self-healing-agent
)

for container in "${RUNNING_CONTAINERS[@]}"; do
  step "Checking ${container} is running"
  running=$(docker inspect -f '{{.State.Running}}' "$container" 2>/dev/null || echo "missing")
  [[ "$running" == "true" ]] || fail "${container} is not running (state=${running})"
done

# ---------------------------------------------------------------------------
# 4. HTTP endpoint probes (sampling: one per stack tier).
# ---------------------------------------------------------------------------
declare -a HTTP_PROBES=(
  "Chatwoot|http://localhost:3000/|200"
  "Dify API|http://localhost:5001/console/api/setup|200"
  "Middleware|http://localhost:4000/health|200"
  "Grafana|http://localhost:3002/login|200"
  "Prometheus|http://localhost:9090/-/healthy|200"
  "Loki|http://localhost:3100/ready|200"
)

for probe in "${HTTP_PROBES[@]}"; do
  IFS="|" read -r name url expected <<< "$probe"
  step "Probing ${name} ${url} (expect ${expected}, up to 1 min)"
  for i in $(seq 1 12); do
    code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
    [[ "$code" == "$expected" ]] && break
    sleep 5
  done
  [[ "$code" == "$expected" ]] || fail "${name} returned ${code} (expected ${expected}) at ${url}"
done

# ---------------------------------------------------------------------------
# 5. Cross-stack network membership: confirm at least one container per
#    stack is attached to nexaduo-network (proves cross-stack DNS works).
# ---------------------------------------------------------------------------
step "Verifying nexaduo-network membership"
members=$(docker network inspect nexaduo-network -f '{{range .Containers}}{{.Name}} {{end}}' 2>/dev/null || echo "")
for required in nexaduo-postgres nexaduo-chatwoot-rails nexaduo-dify-api nexaduo-middleware nexaduo-prometheus; do
  echo "$members" | grep -qw "$required" || fail "nexaduo-network missing container ${required} (members: ${members})"
done

echo "OK all stacks healthy — shared + chatwoot + dify + nexaduo"
trap - EXIT
rm -rf "$LOG_DIR"
