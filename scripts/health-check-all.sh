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
  local name
  # Coolify-managed path (legacy GCP model): match the subName label.
  name="$(docker ps -a \
    --filter "label=coolify.service.subName=${subname}" \
    --format '{{.Names}}' | head -n 1)"
  # Host-local Compose runtime (current, no Coolify labels): fall back to the
  # deterministic Compose container name `nexaduo-<subname>-1`. Without this the
  # whole script was inert on the host-local stack (0 labelled containers), so
  # e.g. an unhealthy dify-api would never be surfaced (issue #41).
  if [[ -z "$name" ]]; then
    name="$(docker ps -a \
      --filter "name=^/nexaduo-${subname}-[0-9]+$" \
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
fi

echo "OK all stacks healthy — shared + chatwoot + dify + nexaduo"
