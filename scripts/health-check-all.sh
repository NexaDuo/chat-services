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
  # issue #158: these 9 moved from RUNNING_SUBNAMES below now that they carry
  # real liveness healthchecks (queue-liveness probe for chatwoot-sidekiq,
  # celery inspect ping for dify-worker, app-level HTTP probes for the rest —
  # see the compose files for each probe's rationale).
  chatwoot-sidekiq
  dify-worker
  dify-web
  evolution-api
  middleware
  loki
  promtail
  grafana
  prometheus
  tempo
  cloudflared
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
  # dify-api moved to HEALTHCHECK_SUBNAMES above (now has a healthcheck, #41).
  # chatwoot-sidekiq/dify-web/dify-worker/evolution-api/middleware/loki/
  # promtail/grafana/prometheus/tempo/cloudflared moved there too (#158).
  # otel-collector deliberately stays here: its image has no exec tool for a
  # Docker-native healthcheck (see deploy/docker-compose.nexaduo.yml) — it's
  # probed separately below via a sibling container's curl/wget instead.
  dify-sandbox
  dify-plugin-daemon
  dify-ssrf-proxy
  otel-collector
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

# otel-collector (issue #158): its image is distroless (no shell/curl/wget
# inside it — verified, every exec attempt fails with "executable file not
# found"), so it can't carry a Docker-native `healthcheck:` and was left in
# RUNNING_SUBNAMES above (running-only, not health-status). The
# `health_check` extension it now exposes (:13133/health,
# observability/otel-collector/config.yaml) is still verified live here, by
# reaching it FROM a sibling container that does have wget — same
# cross-container network the rest of this script already relies on.
otel_container="$(require_container "otel-collector")"
middleware_probe_container="$(require_container "middleware")"
step "Probing otel-collector health_check extension (:13133/health) from inside ${middleware_probe_container} (up to 1 min)"
for i in $(seq 1 12); do
  if docker exec "$middleware_probe_container" wget -qO- http://otel-collector:13133/health >/dev/null 2>&1; then
    break
  fi
  sleep 5
done
docker exec "$middleware_probe_container" wget -qO- http://otel-collector:13133/health >/dev/null 2>&1 \
  || fail "otel-collector health_check extension unreachable at http://otel-collector:13133/health (probed from ${middleware_probe_container}, container ${otel_container}) — collector may be wedged"

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
docker_enabled_count="$(echo "$routers_json" | grep -o '"provider":"docker"[^}]*"status":"enabled"\|"status":"enabled"[^}]*"provider":"docker"' | wc -l || true)"
(( docker_enabled_count > 0 )) || fail "Traefik Docker provider has ZERO enabled routers (found ${docker_enabled_count}) — it may be silently down again (issue #151); routing could be surviving on the file-provider fallback alone without anyone noticing"
echo "  docker-provider routers OK: ${docker_enabled_count} enabled"

# ---------------------------------------------------------------------------
# 4b. Log rotation coverage (issue #156). Only coolify-proxy had a bounded
# log policy (json-file + max-size + max-file, #151/#153); every other
# service accrued logs unbounded — chatwoot-sidekiq measured ~22MB/day, faster
# than the 136k-line #151 incident that motivated rotation in the first
# place. This asserts the *class* of regression (any chat-services-* /
# coolify-proxy container missing a bounded json-file policy AND at its
# documented tier's expected max-size — see below), the same pattern as the
# #153 router-count check, so a future service that forgets to reference the
# shared `x-logging` anchor, OR whose anchor copy silently drifts from the
# other 3 files it's replicated in, is caught here instead of silently
# accruing unrotated logs again.
#
# `@rev`/`@sec` review (issue #156 PR #161) reproduced a false-"OK" in an
# earlier version of this check: filtering `docker ps` through
# `grep -E "^(${COMPOSE_PROJECT_NAME}-|...)"` piped into `while read` means a
# zero-match grep (stack down, or COMPOSE_PROJECT_NAME overridden per
# AGENTS.md #7) makes the loop execute zero times and fall through to the
# same "OK" echo with nothing actually checked — `set -euo pipefail` does NOT
# catch this, because the pipeline's exit status is grep's (1 on no match,
# but `|| true`-equivalent behavior isn't even needed here: the loop body
# just never runs and the script marches on). Fixed the same way the Traefik
# router check above guards against zero enabled routers: count what was
# actually checked and `fail` if that count is zero. Matching is done with
# bash glob `case`, not `grep -E`, so a COMPOSE_PROJECT_NAME containing
# regex metacharacters can't silently break the match (also flagged in the
# same review).
# ---------------------------------------------------------------------------
step "Verifying every running chat-services-*/coolify-proxy container has a bounded log policy"
# `postgres` was skipped pending explicit user sign-off to recreate the
# SACRED `chat-services_postgres-data` volume (issue #156). Signed off and
# recreated 2026-08-07 with `--no-deps` (never `down -v`); verified
# before/after via `docker volume inspect chat-services_postgres-data`
# (identical CreatedAt/Mountpoint) and a `SELECT count(*) FROM conversations`
# row count (3 -> 3, unchanged) — the volume survived and the policy is now
# live (`docker inspect` confirms `json-file max-size=10m max-file=3`). No
# skip needed anymore; default to checking everything.
LOG_POLICY_SKIP_SUBNAMES="${LOG_POLICY_SKIP_SUBNAMES:-}"
# Per-tier expected max-size (issue #156 `@rev` review item 3): the anchor is
# necessarily replicated across 4 compose files (shared/chatwoot/dify/
# nexaduo — YAML anchors don't cross `-f` files), so a value can drift
# unnoticed in one of them. Asserting the effective value against what each
# tier is DOCUMENTED to be (not just "non-empty") catches that drift, not
# just a missing policy.
LOG_POLICY_DEFAULT_MAX_SIZE="${LOG_POLICY_DEFAULT_MAX_SIZE:-10m}"
LOG_POLICY_FORENSIC_MAX_SIZE="${LOG_POLICY_FORENSIC_MAX_SIZE:-20m}"
# max-file per tier (issue #156 second review round, qodo/@techlead item 2):
# the comment above says the policy is "json-file + max-size + max-file", but
# only max-size was ever asserted — a container with max-size set and NO
# max-file passes silently. Severity note (confirmed by reasoning about the
# dockerd default, not measured against a live drifted container): a missing
# max-file does NOT make the container unbounded — dockerd defaults max-file
# to 1 when max-size is set, so the log stays size-bounded — it just loses
# the retained-history depth the tier intends (3 or 4 rotated files instead
# of 1). Treated as the same DRIFT class as max-size, not upgraded to
# UNBOUNDED, so the failure message doesn't overstate the risk.
LOG_POLICY_DEFAULT_MAX_FILE="${LOG_POLICY_DEFAULT_MAX_FILE:-3}"
LOG_POLICY_FORENSIC_MAX_FILE="${LOG_POLICY_FORENSIC_MAX_FILE:-4}"
# chatwoot-sidekiq: byte-heavy noisy tier (deploy/docker-compose.chatwoot.yml).
# dify-sandbox/dify-plugin-daemon: forensic tier for less-trusted code
# execution, independent of measured volume (deploy/docker-compose.dify.yml).
LOG_POLICY_FORENSIC_SUBNAMES="${LOG_POLICY_FORENSIC_SUBNAMES:-chatwoot-sidekiq dify-sandbox dify-plugin-daemon}"

log_policy_bad=0
containers_found=0
containers_checked=0
while IFS= read -r container; do
  [[ -n "$container" ]] || continue
  case "$container" in
    "${COMPOSE_PROJECT_NAME}-"*-[0-9]*|"coolify-proxy") ;;
    *) continue ;;
  esac
  containers_found=$((containers_found + 1))

  # Derive the subname via string ops (not a regex match) so a
  # COMPOSE_PROJECT_NAME with glob/regex metacharacters can't misparse it.
  if [[ "$container" == "coolify-proxy" ]]; then
    subname="coolify-proxy"
  else
    # Quote the prefix so a COMPOSE_PROJECT_NAME containing glob metacharacters
    # (*, ?, []) is stripped literally, not interpreted as a pattern by the
    # `#` removal (`@sec`/`@rev` review of #161).
    rest="${container#"${COMPOSE_PROJECT_NAME}"-}"
    subname="${rest%-*}"
  fi

  skip=0
  for skip_subname in $LOG_POLICY_SKIP_SUBNAMES; do
    if [[ "$subname" == "$skip_subname" ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" == "1" ]]; then
    echo "  WARN: skipping ${container} (pending sign-off — issue #156, SACRED volume recreate)"
    continue
  fi

  expected_max_size="$LOG_POLICY_DEFAULT_MAX_SIZE"
  expected_max_file="$LOG_POLICY_DEFAULT_MAX_FILE"
  for forensic_subname in $LOG_POLICY_FORENSIC_SUBNAMES; do
    if [[ "$subname" == "$forensic_subname" ]]; then
      expected_max_size="$LOG_POLICY_FORENSIC_MAX_SIZE"
      expected_max_file="$LOG_POLICY_FORENSIC_MAX_FILE"
      break
    fi
  done

  containers_checked=$((containers_checked + 1))
  # NOTE (issue #156 second review round, qodo/@techlead item 1): `index` on a
  # Go template map for a MISSING key renders as an EMPTY string, not
  # "<no value>" (that placeholder is a dot-notation/field-lookup artifact,
  # not an `index`-on-map one) — verified empirically against the real live
  # (unbounded) chat-services-postgres-1: `docker inspect -f
  # '{{index .HostConfig.LogConfig.Config "max-size"}}'` printed nothing
  # (confirmed byte-for-byte with `od -c`), so `-z "$max_size"` below DOES
  # correctly catch a missing max-size as UNBOUNDED, not misroute it into the
  # DRIFT branch. Re-verify with `od -c` if the docker/template version ever
  # changes this behavior — don't assume it holds forever.
  # Pipe-delimited, not space-delimited: max-size/max-file are legitimately
  # EMPTY when unset, and whitespace-based field splitting (awk/read with
  # default IFS) collapses consecutive delimiters, silently shifting fields
  # left when a value is missing — exactly the case this check most needs to
  # get right. `|` can't appear in a docker log-driver name or a max-size/
  # max-file value, so it can't be misparsed the same way.
  # Three explicit states, not two (qodo finding on 8fc34d9, `@techlead`
  # 2026-08-07): "container exists" (parse below), "container genuinely
  # vanished mid-scan" (skip — not a log-policy fact to assert), and "could
  # not determine" (a transient docker-daemon hiccup, DNS blip, whatever —
  # this MUST fail loud, never be silently treated as either of the other
  # two). The previous fix conflated the last two: it re-ran
  # `docker ps | grep -qx "$container"` to decide "gone", but (a) unquoted
  # `-qx` uses the container name as a *regex*, not a literal, so a name
  # containing regex metacharacters could false-match or false-miss, and (b)
  # any failure of that SECOND docker call (e.g. the daemon hiccupping a
  # second time) also makes grep return empty/1, which was indistinguishable
  # from "confirmed gone" — routing a genuine "I don't know" into the
  # skip/no-op branch, the exact silent-passthrough class issue #156 exists
  # to catch. Fixed by making a single `docker inspect` call the sole source
  # of truth: capture ITS OWN stderr (not a second, independently-fallible
  # command) and use `docker inspect`'s own well-known "No such object"
  # message (verified below) to identify "gone" specifically. Any other
  # failure (daemon down, socket error, permission, anything) falls through
  # to the FAIL branch — it is NOT masked as a driver/max-size mismatch check
  # here, because a container we can't even inspect isn't grounds to trust
  # or distrust the last known UNBOUNDED/DRIFT verdict for it, and NOT
  # skipped, because "couldn't determine" must never look like a pass.
  if log_config="$(docker inspect -f '{{.HostConfig.LogConfig.Type}}|{{index .HostConfig.LogConfig.Config "max-size"}}|{{index .HostConfig.LogConfig.Config "max-file"}}' "$container" 2>&1)"; then
    IFS='|' read -r driver max_size max_file <<< "$log_config"
  else
    # `log_config` now holds docker inspect's own combined stdout+stderr (there
    # is no real stdout on failure — the template never rendered, just a
    # leading blank line before the error text). Verified empirically against
    # this host's real docker CLI (29.7.1): the message is a lowercase
    # `error: no such object: <name>` with a leading `\n` (confirmed with
    # `od -c` — don't assume format/case across docker versions). Matched
    # case-insensitively on a fixed substring, NOT a pattern built from
    # `$container` (that was the qodo-flagged bug: using the container name
    # as a grep/glob pattern instead of a literal).
    if [[ "${log_config,,}" == *"no such object"* ]]; then
      echo "  WARN: skipping ${container} (removed mid-scan — docker inspect: ${log_config})" >&2
      containers_checked=$((containers_checked - 1))
      continue
    fi
    echo "  FAIL-ITEM: could not determine log policy for ${container} (docker inspect error, not a confirmed removal): ${log_config}" >&2
    log_policy_bad=1
    continue
  fi
  if [[ "$driver" != "json-file" || -z "$max_size" ]]; then
    echo "  UNBOUNDED: ${container} (driver=${driver:-none} max-size=${max_size:-unset})" >&2
    log_policy_bad=1
  elif [[ "$max_size" != "$expected_max_size" || -z "$max_file" || "$max_file" != "$expected_max_file" ]]; then
    echo "  DRIFT: ${container} (subname=${subname}) has max-size=${max_size} max-file=${max_file:-unset}, expected max-size=${expected_max_size} max-file=${expected_max_file} for its tier — an anchor copy has diverged (issue #156). This is a retention-depth drift, not a disk-unbounded one: dockerd defaults max-file to 1 when only max-size is set, so the log stays size-bounded either way." >&2
    log_policy_bad=1
  fi
done < <(docker ps --format '{{.Names}}')

(( containers_found > 0 )) || fail "no chat-services-*/coolify-proxy containers found — is the stack up, and does COMPOSE_PROJECT_NAME (currently '${COMPOSE_PROJECT_NAME}') match the running project? A zero-match here previously produced a false 'OK' (issue #156 @rev/@sec review) — this now fails loud instead."
# issue #156 second review round item 3: if EVERY matched container fell into
# the skip list, nothing was actually asserted this run. The skip list is
# operator-configurable and documented to grow (currently just `postgres`,
# pending its live sign-off) — the day it grows to cover everything running,
# a WARN-only outcome would let this exact "check that doesn't check" class
# of regression back in silently, which is the whole premise of #156. FAIL
# instead: a health check that can't prove it checked anything is not a
# passing health check.
(( containers_checked > 0 )) || fail "${containers_found} container(s) matched but ALL were skipped (LOG_POLICY_SKIP_SUBNAMES='${LOG_POLICY_SKIP_SUBNAMES}') — no log policy was actually asserted this run. If this is expected (e.g. a deliberate temporary skip), it must not be the ONLY outcome of a health check; narrow the skip list or add a compliant container to check."
(( log_policy_bad == 0 )) || fail "one or more containers have an unbounded/non-json-file/drifted log policy (issue #156 regression) — see UNBOUNDED/DRIFT lines above"
echo "  log rotation coverage OK (${containers_checked} checked, ${containers_found} found)"

# ---------------------------------------------------------------------------
# 4c. Memory-limit coverage (issue #157). Before this, `grep -rn
# "mem_limit\|cpus:\|deploy:\|resources:"` across the whole compose chain
# returned zero matches — every container ran with the full host RAM
# (`docker stats` showed `<X>MiB / 30.97GiB` on all 22 running containers).
# On a shared production host with no staging, a runaway container had
# nothing at the code level stopping it from triggering a host-level OOM,
# and the kernel OOM-killer picks a victim by heuristic, not by culprit — it
# could just as easily pick `chat-services-postgres-1` (SACRED data) as the
# actual offender. mem_limit is now set per service across the compose
# chain (deploy/docker-compose.{shared,chatwoot,dify,nexaduo,localproxy}.yml
# — docker-compose.yml carries only cross-stack `depends_on`/dev overrides,
# no service definitions of its own, so it needed no change here), sized
# from measured `docker stats` baselines with a 4x-6x headroom multiple (see
# the per-service comments in those files for the exact figure and its
# origin).
#
# `postgres` is DELIBERATELY EXCLUDED from this check (and from the compose
# change) — see deploy/docker-compose.shared.yml: a mem_limit sized below
# what shared_buffers/work_mem can demand OOM-kills the database under load,
# and AGENTS.md requires it to get its own change with its own validation,
# not be folded into a bulk sweep.
#
# `@rev` HIGH finding on PR #164 (issue #157): the first version of this
# exception was an env-overridable `MEM_LIMIT_SKIP_SUBNAMES` variable —
# mechanically identical to `LOG_POLICY_SKIP_SUBNAMES` above despite a
# comment claiming otherwise, and reproduced live:
# `MEM_LIMIT_SKIP_SUBNAMES="postgres middleware"` made this check print OK
# and exit 0 with `middleware` unlimited and silently uncaught. This is the
# sixth variant of the "check that doesn't check" bug in this file this
# session, and it landed in the exact assertion written to prevent it, with
# a comment asserting it was safe. A comment asserting something is safe
# does not make it safe — fixed by making `postgres` a HARDCODED literal
# below, not a variable of any kind bash can expand from the environment.
# There is no override, on purpose: an operator who genuinely needs a
# temporary second exception edits this line in a reviewed commit, not an
# env var that can leak in from a shell profile or a stray export.
#
# Same three-outcome shape as the log-policy check above (issue #156):
# "found" (matched the naming pattern), "checked" (found AND not the
# hardcoded postgres exception), and a hard `fail` if either count comes
# back zero — a health check that can't prove it checked anything is not a
# passing health check (issue #156's own lesson, applied here too).
#
# `@rev` MEDIUM finding: a non-zero HostConfig.Memory only proves SOME limit
# exists, not that it matches what the compose file declares — someone
# could lower it by hand on the host and this would stay green. Compared
# below against MEM_LIMIT_EXPECTED_MIB, a hardcoded per-subname map of the
# exact `mem_limit` values committed in the compose files (same spirit as
# the log-policy tier comparison above) — a subname missing from this map
# is ALSO a failure (not a silent pass), so a new service added with a
# mem_limit but never added here is caught too, not just a value drift.
# This map is a second source of truth that WILL drift from the compose
# files if only one side is edited — keep it in sync by hand when a
# mem_limit changes (there is no single-source alternative here without
# this script depending on the exact -f chain/`.env` run-stack.sh uses,
# which this file has never required for any other check).
# ---------------------------------------------------------------------------
step "Verifying every running chat-services-*/coolify-proxy container (except postgres) has a memory limit matching its declared value"

declare -A MEM_LIMIT_EXPECTED_MIB=(
  [chatwoot-init]=1024
  [chatwoot-rails]=1536
  [chatwoot-sidekiq]=2048
  [dify-init]=128
  [dify-api]=1664
  [dify-worker]=2176
  [dify-web]=384
  [dify-sandbox]=512
  [dify-plugin-daemon]=640
  [dify-ssrf-proxy]=128
  [evolution-api]=512
  [middleware]=256
  [loki]=512
  [promtail]=384
  [grafana]=640
  [prometheus]=384
  [self-healing-agent]=128
  [otel-collector]=384
  [tempo]=768
  [redis]=256
  [cloudflared]=128
  [autoheal]=128
  [coolify-proxy]=256
)

mem_limit_bad=0
mem_containers_found=0
mem_containers_checked=0
while IFS= read -r container; do
  [[ -n "$container" ]] || continue
  case "$container" in
    "${COMPOSE_PROJECT_NAME}-"*-[0-9]*|"coolify-proxy") ;;
    *) continue ;;
  esac
  mem_containers_found=$((mem_containers_found + 1))

  if [[ "$container" == "coolify-proxy" ]]; then
    subname="coolify-proxy"
  else
    rest="${container#"${COMPOSE_PROJECT_NAME}"-}"
    subname="${rest%-*}"
  fi

  # Hardcoded, not a variable — see the rationale above. This is the ONLY
  # exception and it cannot be expanded/overridden from the environment.
  if [[ "$subname" == "postgres" ]]; then
    echo "  WARN: skipping ${container} (issue #157 — postgres deferred to its own change/validation, never a mem_limit lower than its configured shared_buffers/work_mem can demand)"
    continue
  fi

  mem_containers_checked=$((mem_containers_checked + 1))
  # Same "three explicit states" discipline as the log-policy check above:
  # a container that vanished mid-scan is skipped (not a fact to assert), a
  # docker-inspect error for any OTHER reason must fail loud (never silently
  # pass as "has a limit"), and only a successful inspect is evaluated.
  if mem_limit_bytes="$(docker inspect -f '{{.HostConfig.Memory}}' "$container" 2>&1)"; then
    :
  else
    if [[ "${mem_limit_bytes,,}" == *"no such object"* ]]; then
      echo "  WARN: skipping ${container} (removed mid-scan — docker inspect: ${mem_limit_bytes})" >&2
      mem_containers_checked=$((mem_containers_checked - 1))
      continue
    fi
    echo "  FAIL-ITEM: could not determine memory limit for ${container} (docker inspect error, not a confirmed removal): ${mem_limit_bytes}" >&2
    mem_limit_bad=1
    continue
  fi
  # HostConfig.Memory is 0 when no mem_limit/--memory was set (unbounded —
  # the container's ceiling is the full host RAM, exactly the #157 gap).
  if [[ -z "$mem_limit_bytes" || "$mem_limit_bytes" == "0" ]]; then
    echo "  UNBOUNDED: ${container} has no memory limit (HostConfig.Memory=0 — full host RAM is its ceiling)" >&2
    mem_limit_bad=1
    continue
  fi
  expected_mib="${MEM_LIMIT_EXPECTED_MIB[$subname]:-}"
  if [[ -z "$expected_mib" ]]; then
    echo "  FAIL-ITEM: ${container} (subname=${subname}) has a memory limit (${mem_limit_bytes} bytes) but is NOT in MEM_LIMIT_EXPECTED_MIB — add its declared mem_limit to scripts/health-check-all.sh so drift can be detected." >&2
    mem_limit_bad=1
    continue
  fi
  actual_mib=$(( mem_limit_bytes / 1048576 ))
  if [[ "$actual_mib" != "$expected_mib" ]]; then
    echo "  DRIFT: ${container} (subname=${subname}) has mem_limit=${actual_mib}MiB, expected ${expected_mib}MiB per the compose file — the live limit no longer matches what's declared in source (issue #157 regression class)." >&2
    mem_limit_bad=1
  fi
done < <(docker ps --format '{{.Names}}')

(( mem_containers_found > 0 )) || fail "no chat-services-*/coolify-proxy containers found — is the stack up, and does COMPOSE_PROJECT_NAME (currently '${COMPOSE_PROJECT_NAME}') match the running project?"
(( mem_containers_checked > 0 )) || fail "${mem_containers_found} container(s) matched but ALL were skipped — no memory-limit coverage was actually asserted this run."
(( mem_limit_bad == 0 )) || fail "one or more containers have no memory limit, an undeclared one, or a limit drifted from the compose file (issue #157 regression) — see UNBOUNDED/DRIFT/FAIL-ITEM lines above"
echo "  memory-limit coverage OK (${mem_containers_checked} checked, ${mem_containers_found} found, postgres deliberately excluded)"

# ---------------------------------------------------------------------------
# 4d. Healthcheck coverage (issue #158). Before this, 11 running services
# (chatwoot-sidekiq, dify-worker, dify-web, middleware, evolution-api,
# cloudflared, grafana, loki, prometheus, tempo, otel-collector) had NO
# healthcheck at all — Docker's `restart: unless-stopped` only reacts to a
# process EXITING, so a wedged-but-alive process (a sidekiq that stops
# draining jobs, a wedged tunnel) was invisible to Docker, to `autoheal`,
# and to section 3 above (which only asserts "exists and is running").
# Same three-outcome discipline as the log-policy/mem-limit checks above
# (issue #156/#157): a container with no configured healthcheck AND not on
# the skip list below is a coverage gap and FAILS this check — never a
# silent pass. A container WITH a healthcheck must also report `healthy`
# (not `starting`/`unhealthy`), catching the case where the healthcheck
# exists but is currently failing.
#
# The skip list is a fixed bash array, NOT an env-var-overridable string
# (issue #157 review history, `@rev` on #164): an earlier version of the
# mem-limit check let ANY env var silence the entire assertion, which is
# exactly the failure mode this whole file exists to catch (issue #156's own
# lesson). If this list ever needs to change, that's a source-code diff and
# a reviewed PR, not a runtime knob.
# ---------------------------------------------------------------------------
step "Verifying every running chat-services-*/coolify-proxy container has a healthcheck AND reports healthy"
# otel-collector: distroless image, no exec tool for a Docker-native
# healthcheck (see deploy/docker-compose.nexaduo.yml and the otel-collector
# probe above, which covers it via a sibling container instead).
# dify-sandbox/dify-plugin-daemon/dify-ssrf-proxy/self-healing-agent/autoheal:
# out of scope for issue #158 (not in its affected-surface list); left for a
# follow-up rather than folded in here undocumented.
HEALTHCHECK_COVERAGE_SKIP_SUBNAMES=(otel-collector dify-sandbox dify-plugin-daemon dify-ssrf-proxy self-healing-agent autoheal)

hc_bad=0
hc_containers_found=0
hc_containers_checked=0
while IFS= read -r container; do
  [[ -n "$container" ]] || continue
  case "$container" in
    "${COMPOSE_PROJECT_NAME}-"*-[0-9]*|"coolify-proxy") ;;
    *) continue ;;
  esac
  hc_containers_found=$((hc_containers_found + 1))

  if [[ "$container" == "coolify-proxy" ]]; then
    subname="coolify-proxy"
  else
    rest="${container#"${COMPOSE_PROJECT_NAME}"-}"
    subname="${rest%-*}"
  fi

  skip=0
  for skip_subname in "${HEALTHCHECK_COVERAGE_SKIP_SUBNAMES[@]}"; do
    if [[ "$subname" == "$skip_subname" ]]; then
      skip=1
      break
    fi
  done
  if [[ "$skip" == "1" ]]; then
    echo "  WARN: skipping ${container} (documented exception — issue #158, see deploy compose comment for ${subname})"
    continue
  fi

  hc_containers_checked=$((hc_containers_checked + 1))
  # Same "three explicit states" discipline as log-policy/mem-limit above: a
  # container gone mid-scan is skipped (not a fact to assert), any OTHER
  # docker-inspect failure FAILS loud (never silently treated as compliant),
  # and only a successful inspect is evaluated. `.State.Health.Status` on a
  # container with NO configured healthcheck renders as an empty string
  # (there is no `.State.Health` key at all), which is exactly the
  # NO-HEALTHCHECK case this check needs to catch.
  if health_status="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$container" 2>&1)"; then
    :
  else
    if [[ "${health_status,,}" == *"no such object"* ]]; then
      echo "  WARN: skipping ${container} (removed mid-scan — docker inspect: ${health_status})" >&2
      hc_containers_checked=$((hc_containers_checked - 1))
      continue
    fi
    echo "  FAIL-ITEM: could not determine health status for ${container} (docker inspect error, not a confirmed removal): ${health_status}" >&2
    hc_bad=1
    continue
  fi
  if [[ -z "$health_status" ]]; then
    echo "  NO-HEALTHCHECK: ${container} (subname=${subname}) has no healthcheck configured (issue #158 regression)" >&2
    hc_bad=1
  elif [[ "$health_status" != "healthy" ]]; then
    echo "  UNHEALTHY: ${container} (subname=${subname}) healthcheck status=${health_status}" >&2
    hc_bad=1
  fi
done < <(docker ps --format '{{.Names}}')

(( hc_containers_found > 0 )) || fail "no chat-services-*/coolify-proxy containers found — is the stack up, and does COMPOSE_PROJECT_NAME (currently '${COMPOSE_PROJECT_NAME}') match the running project?"
(( hc_containers_checked > 0 )) || fail "${hc_containers_found} container(s) matched but ALL were skipped (fixed skip list: ${HEALTHCHECK_COVERAGE_SKIP_SUBNAMES[*]}) — no healthcheck coverage was actually asserted this run."
(( hc_bad == 0 )) || fail "one or more containers have no healthcheck configured or are not reporting healthy (issue #158 regression) — see NO-HEALTHCHECK/UNHEALTHY lines above"
echo "  healthcheck coverage OK (${hc_containers_checked} checked, ${hc_containers_found} found)"

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

# ---------------------------------------------------------------------------
# 7. Grafana Dify token-usage alert rules (issue #182) must still be
#    evaluating. Skippable via SKIP_ALERT_HEALTH_CHECK=1 (e.g. ephemeral CI
#    with no Grafana provisioning mounted). An alert rule that silently stops
#    being evaluated (broken provisioning file, query erroring against
#    Prometheus) is worse than no alert — it produces false confidence right
#    when a real spike could be happening. Uses the grafana container's own
#    GF_SECURITY_ADMIN_PASSWORD env var (never printed) to authenticate, so
#    no secret needs to be sourced or logged by this script.
# ---------------------------------------------------------------------------
if [[ "${SKIP_ALERT_HEALTH_CHECK:-0}" == "1" ]]; then
  step "Skipping Grafana alert-rule health check (SKIP_ALERT_HEALTH_CHECK=1)"
else
  grafana_container="$(container_by_subname grafana)"
  if [[ -z "$grafana_container" ]]; then
    step "Skipping Grafana alert-rule health check (no grafana container found)"
  else
    step "Checking Dify token-usage alert rules are healthy and being evaluated"
    rules_json="$(docker exec "$grafana_container" sh -c \
      'AUTH=$(printf "admin:%s" "$GF_SECURITY_ADMIN_PASSWORD" | base64); wget -qO- --header="Authorization: Basic $AUTH" http://127.0.0.1:3000/api/prometheus/grafana/api/v1/rules' \
      2>/dev/null || true)"
    [[ -n "$rules_json" ]] || fail "could not reach Grafana's alert-rules API inside ${grafana_container} — is grafana up?"
    for rule_uid in dify-tokens-aggregate-spike dify-tokens-per-account-spike; do
      echo "$rules_json" | grep -q "\"uid\":\"${rule_uid}\"" \
        || fail "alert rule ${rule_uid} not found via Grafana API — provisioning file observability/grafana/provisioning/alerting/dify-token-usage.yml did not load (issue #182)"
    done
    echo "$rules_json" | grep -q '"health":"error"' \
      && fail "at least one Dify token-usage alert rule reports health=error — check its query/datasource (issue #182)"
    echo "  Dify token-usage alert rules present and healthy"
  fi
fi

echo "OK all stacks healthy — shared + chatwoot + dify + nexaduo"
