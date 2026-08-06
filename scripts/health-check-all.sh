#!/usr/bin/env bash
# =============================================================================
# health-check-all.sh — non-destructive end-to-end probe for the live
# NexaDuo stack across all four Coolify stacks (shared, chatwoot, dify,
# nexaduo). Safe to run anytime — does NOT touch state or volumes.
#
# Exit 0 = all services healthy. Non-zero = first failing check + log tail.
# =============================================================================
set -euo pipefail

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-chat-services}"

step() { echo "==> $*"; }
fail() {
  echo "FAIL: $1" >&2
  exit 1
}

container_by_subname() {
  local subname="$1"
  local name
  # Coolify-managed path (legacy GCP model): match the subName label.
  name="$(docker ps -a \
    --filter "label=coolify.service.subName=${subname}" \
    --format '{{.Names}}' | head -n 1)"
  # Host-local Compose runtime (current, no Coolify labels): fall back to the
  # deterministic Compose container name `${COMPOSE_PROJECT_NAME}-<subname>-1`.
  # Without this the whole script was inert on the host-local stack (0 labelled
  # containers), so e.g. an unhealthy dify-api would never be surfaced (issue #41).
  if [[ -z "$name" ]]; then
    name="$(docker ps -a \
      --filter "name=^/${COMPOSE_PROJECT_NAME}-${subname}-[0-9]+$" \
      --format '{{.Names}}' | head -n 1)"
  fi
  echo "$name"
}

require_container() {
  local subname="$1"
  local name
  name="$(container_by_subname "$subname")"
  [[ -n "$name" ]] || fail "container for subName=${subname} not found"
  echo "$name"
}

# ---------------------------------------------------------------------------
# 1. Restart-loop / unhealthy detector across all Coolify-labelled containers.
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
  # dify-api has a worker-served /health healthcheck (issue #41): a gunicorn
  # master that bound :5001 with zero workers stays Running=true but goes
  # unhealthy, so verifying `healthy` (not just running) surfaces that state.
  dify-api
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
  # dify-api moved to HEALTHCHECK_SUBNAMES above (now has a healthcheck, #41).
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
# Probed FROM INSIDE each container (docker exec), not via a host-published
# port: since #119 the stack normally runs isolated (`run-stack.sh --isolated
# up`), which publishes ZERO host ports, so `curl localhost:<port>` from the
# host would always fail there. Internal probing works in both modes.
# ---------------------------------------------------------------------------
probe_internal() {
  local container="$1" url="$2"
  docker exec "$container" sh -c '
    if command -v curl >/dev/null 2>&1; then
      curl -s -o /dev/null -w "%{http_code}" "'"$url"'"
    elif command -v wget >/dev/null 2>&1; then
      wget -S -q -O /dev/null "'"$url"'" 2>&1 | awk "/^ *HTTP\// {print \$2}" | tail -1
    else
      echo 000
    fi
  ' 2>/dev/null || echo 000
}

declare -a HTTP_PROBES=(
  "Chatwoot|chatwoot-rails|http://127.0.0.1:3000/|200,301,302"
  "Dify API|dify-api|http://127.0.0.1:5001/console/api/setup|200"
  "Middleware|middleware|http://127.0.0.1:4000/health|200"
  "Grafana|grafana|http://127.0.0.1:3000/login|200"
  "Prometheus|prometheus|http://127.0.0.1:9090/-/healthy|200"
)

for probe in "${HTTP_PROBES[@]}"; do
  IFS="|" read -r name subname url expected_codes <<< "$probe"
  container="$(require_container "$subname")"
  step "Probing ${name} (${container}) ${url} (expect one of ${expected_codes}, up to 1 min)"
  for i in $(seq 1 12); do
    code="$(probe_internal "$container" "$url")"
    echo ",${expected_codes}," | grep -q ",${code}," && break
    sleep 5
  done
  echo ",${expected_codes}," | grep -q ",${code}," || fail "${name} returned ${code} (expected one of ${expected_codes}) at ${url} (inside ${container})"
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
  middleware_container="$(require_container "middleware")"
  step "Probing Middleware /config (Bearer auth) inside ${middleware_container}"
  code="$(docker exec "$middleware_container" sh -c '
    if command -v curl >/dev/null 2>&1; then
      curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer '"${HANDOFF_SHARED_SECRET}"'" http://127.0.0.1:4000/config
    elif command -v wget >/dev/null 2>&1; then
      wget -S -q -O /dev/null --header="Authorization: Bearer '"${HANDOFF_SHARED_SECRET}"'" http://127.0.0.1:4000/config 2>&1 | awk "/^ *HTTP\// {print \$2}" | tail -1
    else
      echo 000
    fi
  ' 2>/dev/null || echo 000)"
  [[ "$code" == "200" ]] || fail "Middleware /config returned ${code} (expected 200)"
else
  echo "WARN: skipping Middleware /config probe (HANDOFF_SHARED_SECRET unavailable)"
fi

# self-healing-agent must have received the same secret (issue #152: it was
# silently missing from this container while present in middleware's) and
# must have successfully exchanged it for a Dify key on boot — check
# presence only (never echo the value) plus the boot log line, not merely
# that the env var is non-empty.
#
# SELF_HEALING_ALLOW_NO_CONFIG=1 is the agent's OWN explicit escape hatch
# (CI/dev detection-only mode, issue #152/#22) — a stack running with it set
# legitimately has no secret and never logs "Remote config fetched
# successfully". Read the flag from the container itself (never inferred) so
# this check doesn't contradict the agent's documented behaviour: WARN
# instead of FAIL in that mode, and assert the allow-mode log line instead.
# Production (flag unset/not "1") stays fail-closed — do not weaken that path.
self_healing_container="$(container_by_subname "self-healing-agent")"
if [[ -n "$self_healing_container" ]]; then
  allow_no_config="$(docker exec "$self_healing_container" sh -c 'echo "${SELF_HEALING_ALLOW_NO_CONFIG:-}"' 2>/dev/null || true)"

  if [[ "$allow_no_config" == "1" ]]; then
    echo "WARN: ${self_healing_container} runs with SELF_HEALING_ALLOW_NO_CONFIG=1 (CI/dev detection-only mode) — skipping strict HANDOFF_SHARED_SECRET/config assertions"
    step "Checking ${self_healing_container} logged the explicit detection-only degrade line"
    docker logs "$self_healing_container" 2>&1 | grep -q "allowed via SELF_HEALING_ALLOW_NO_CONFIG" \
      || echo "WARN: no detection-only degrade line seen yet in ${self_healing_container} logs (may still be starting)"
  else
    step "Checking HANDOFF_SHARED_SECRET reaches ${self_healing_container}"
    docker exec "$self_healing_container" sh -c '[ -n "$HANDOFF_SHARED_SECRET" ]' \
      || fail "HANDOFF_SHARED_SECRET is empty inside ${self_healing_container} (issue #152 regression) and SELF_HEALING_ALLOW_NO_CONFIG!=1"

    step "Checking ${self_healing_container} fetched remote config on boot"
    if docker logs "$self_healing_container" 2>&1 | grep -q "Remote config fetched successfully"; then
      :
    elif docker logs "$self_healing_container" 2>&1 | grep -qE "FATAL: (HANDOFF_SHARED_SECRET not set|exhausted retries fetching /config)"; then
      fail "${self_healing_container} failed loud fetching remote config — see 'docker logs ${self_healing_container}'"
    else
      echo "WARN: no 'Remote config fetched successfully' line yet in ${self_healing_container} logs (may still be retrying/starting)"
    fi
  fi
else
  echo "WARN: skipping self-healing-agent config check (container not found)"
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
# Traefik Docker-provider routing check (issue #151). The Docker provider was
# found permanently down for weeks — retrying "Error response from daemon: "
# forever — while routing kept working invisibly on the file-provider
# fallback (deploy/traefik/dynamic.yml). A check that only warns is exactly
# how that survived undetected, so this FAILS the health check outright if
# no docker-provider router is present/enabled, instead of just logging it.
# Queried via the Traefik API, gated to 127.0.0.1 only (ipAllowList in
# dynamic.yml — issue #151 @sec) — must run via `docker exec` into
# coolify-proxy itself, not reachable from any other container.
# Assert the invariant that matters (docker-provider routers exist and are
# enabled), not a hardcoded exact count — the service list is expected to
# grow and a brittle count would need updating every time a service is added.
# ---------------------------------------------------------------------------
# coolify-proxy has a fixed `container_name: coolify-proxy` in
# deploy/docker-compose.localproxy.yml (not project-name-templated like the
# other services), so look it up directly rather than via require_container.
proxy_container="coolify-proxy"
docker inspect "$proxy_container" >/dev/null 2>&1 || fail "container ${proxy_container} not found"
step "Verifying Traefik Docker-provider routers inside ${proxy_container}"
routers_json="$(docker exec "$proxy_container" wget -qO- http://127.0.0.1:8080/api/http/routers 2>/dev/null || echo "")"
[[ -n "$routers_json" ]] || fail "Traefik API unreachable inside ${proxy_container} (http://127.0.0.1:8080/api/http/routers) — is --api enabled and the ipAllowList/dynamic.yml router in place?"
docker_enabled_count="$(echo "$routers_json" | grep -o '"provider":"docker"[^}]*"status":"enabled"\|"status":"enabled"[^}]*"provider":"docker"' | wc -l)"
(( docker_enabled_count > 0 )) || fail "Traefik Docker provider has ZERO enabled routers (found ${docker_enabled_count}) — it may be silently down again (issue #151); routing could be surviving on the file-provider fallback alone without anyone noticing"
echo "  docker-provider routers OK: ${docker_enabled_count} enabled"

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

# ---------------------------------------------------------------------------
# 6. Backup freshness (issue #121). The daily pg_dump cron failed SILENTLY for
#    days because it pointed at a renamed script — no dump, no alarm. Flag if the
#    newest dump in BACKUP_DIR is older than BACKUP_MAX_AGE_HOURS (default 26h =
#    one 03:00 run + slack). This is the guard so a broken/stale backup never
#    goes unnoticed again. Skippable via SKIP_BACKUP_CHECK=1 (e.g. ephemeral CI
#    where no backups are expected).
# ---------------------------------------------------------------------------
if [[ "${SKIP_BACKUP_CHECK:-0}" == "1" ]]; then
  step "Skipping backup freshness check (SKIP_BACKUP_CHECK=1)"
else
  BACKUP_DIR="${BACKUP_DIR:-${HOME}/nexaduo-local/dumps}"
  BACKUP_MAX_AGE_HOURS="${BACKUP_MAX_AGE_HOURS:-26}"
  step "Checking backup freshness in ${BACKUP_DIR} (max age ${BACKUP_MAX_AGE_HOURS}h)"
  [[ -d "$BACKUP_DIR" ]] || fail "backup dir ${BACKUP_DIR} does not exist (no dumps ever taken?)"
  newest_dump="$(find "$BACKUP_DIR" -type f -name '*.sql.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1)"
  [[ -n "$newest_dump" ]] || fail "no *.sql.gz dumps in ${BACKUP_DIR} — daily backup cron is not producing dumps"
  dump_epoch="${newest_dump%% *}"; dump_file="${newest_dump#* }"
  dump_age_h=$(( ( $(date +%s) - ${dump_epoch%.*} ) / 3600 ))
  if (( dump_age_h >= BACKUP_MAX_AGE_HOURS )); then
    echo "newest dump: $(basename "$dump_file") is ${dump_age_h}h old" >&2
    fail "STALE BACKUP: newest dump is ${dump_age_h}h old (>= ${BACKUP_MAX_AGE_HOURS}h). Daily cron likely broken — run 'scripts/run-stack.sh install-cron'."
  fi
  echo "  backup OK: newest dump $(basename "$dump_file") is ${dump_age_h}h old"

  # Volume-archive freshness (issue #61). pg_dump does NOT capture Docker volumes
  # (chatwoot-storage uploads, Dify RSA privkeys); backup-host.sh now tars them as
  # *<suffix>-<ts>.tar.gz. A fresh DB dump while the volume archive is missing/stale
  # is the exact gap that caused #61 (DB-only restore → FileNotFoundError 500s) —
  # so gate on the volume archives too.
  BACKUP_VOLUME_SUFFIXES="${BACKUP_VOLUME_SUFFIXES:-chatwoot-storage dify-api-storage}"
  for suffix in $BACKUP_VOLUME_SUFFIXES; do
    newest_vol="$(find "$BACKUP_DIR" -type f -name "*${suffix}-*.tar.gz" -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1)"
    [[ -n "$newest_vol" ]] || fail "no volume archive *${suffix}-*.tar.gz in ${BACKUP_DIR} — backup is NOT capturing the '${suffix}' Docker volume (pg_dump ≠ full backup; issue #61)"
    vol_epoch="${newest_vol%% *}"; vol_file="${newest_vol#* }"
    vol_age_h=$(( ( $(date +%s) - ${vol_epoch%.*} ) / 3600 ))
    if (( vol_age_h >= BACKUP_MAX_AGE_HOURS )); then
      echo "newest ${suffix} archive: $(basename "$vol_file") is ${vol_age_h}h old" >&2
      fail "STALE VOLUME BACKUP: newest '${suffix}' archive is ${vol_age_h}h old (>= ${BACKUP_MAX_AGE_HOURS}h). Volume archival broken — check scripts/backup-host.sh."
    fi
    echo "  volume backup OK: newest ${suffix} archive $(basename "$vol_file") is ${vol_age_h}h old"
  done

  # .env freshness — the host .env is production secrets (TUNNEL_TOKEN, DB
  # passwords, Azure OpenAI creds) and is NOT in git; backup-host.sh archives it
  # as env-<ts>.tar.gz alongside the dumps/volumes. Without it a DB+volume
  # restore alone can't reconnect or reach the tunnel, so gate on it too.
  newest_env="$(find "$BACKUP_DIR" -type f -name 'env-*.tar.gz' -printf '%T@ %p\n' 2>/dev/null | sort -rn | head -n1)"
  [[ -n "$newest_env" ]] || fail "no env-*.tar.gz in ${BACKUP_DIR} — backup is NOT capturing the host .env (production secrets)."
  env_epoch="${newest_env%% *}"; env_file_found="${newest_env#* }"
  env_age_h=$(( ( $(date +%s) - ${env_epoch%.*} ) / 3600 ))
  if (( env_age_h >= BACKUP_MAX_AGE_HOURS )); then
    echo "newest .env archive: $(basename "$env_file_found") is ${env_age_h}h old" >&2
    fail "STALE ENV BACKUP: newest .env archive is ${env_age_h}h old (>= ${BACKUP_MAX_AGE_HOURS}h). Check scripts/backup-host.sh."
  fi
  echo "  env backup OK: newest .env archive $(basename "$env_file_found") is ${env_age_h}h old"
fi

echo "OK all stacks healthy — shared + chatwoot + dify + nexaduo"
