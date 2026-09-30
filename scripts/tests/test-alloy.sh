#!/usr/bin/env bash
# Real Alloy -> Loki; synthetic Docker logs only, including on a shared host.
# Internal log pipeline regression, no browser flow: Playwright N/A.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ${1:-} != --bounded ]]; then
  exec timeout --signal=TERM --kill-after=10s 105s bash "$0" --bounded
fi
prefix="w2b-alloy-$(cat /proc/sys/kernel/random/uuid)"
network="$prefix-net"; loki="$prefix-loki"; alloy="$prefix-alloy"
fixture="$prefix-compose"; coolify="$prefix-coolify"; verify="$prefix-verify"
tmp=$(mktemp -d /tmp/w2b-alloy.XXXXXX)
proxy_pid=''
cleanup() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then cat "$tmp/query.json" "$tmp/series.json" "$tmp/proxy.log" 2>/dev/null || true; docker logs "$alloy" 2>&1 || true; docker logs "$loki" 2>&1 || true; fi
  timeout 5s docker rm -f -v "$alloy" "$loki" "$fixture" "$coolify" "$verify" >/dev/null 2>&1 || true
  [[ -z "$proxy_pid" ]] || { kill "$proxy_pid" 2>/dev/null || true; wait "$proxy_pid" 2>/dev/null || true; }
  timeout 2s docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
image=$(sed -n 's/^    image: \(grafana\/alloy:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
loki_image=$(sed -n 's/^    image: \(grafana\/loki:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
# Only the major + immutable digest are constrained; patch upgrades need no test edit.
[[ $image =~ ^grafana/alloy:v?1\.[^@]+@sha256:[a-f0-9]{64}$ ]]
[[ $loki_image =~ ^grafana/loki:3\.[^@]+@sha256:[a-f0-9]{64}$ ]]
# Render the actual CI and isolated chains using synthetic inputs, never .env.
python3 - "$ROOT" "$tmp/compose.env" <<'PYENV'
import pathlib, re, sys
root = pathlib.Path(sys.argv[1])
files = [root / 'deploy' / ('docker-compose.' + name + '.yml')
         for name in ('shared', 'chatwoot', 'dify', 'nexaduo', 'ci')]
files.append(root / 'docker-compose.yml')
keys = set().union(*(set(re.findall(r'\$\{([A-Z_][A-Z0-9_]*)\}', p.read_text())) for p in files))
values = dict.fromkeys(keys, 'synthetic')
values.update(NEXADUO_CONF_PATH=str(root), PWD=str(root),
              MIDDLEWARE_IMAGE='synthetic/middleware:local',
              SELF_HEALING_IMAGE='synthetic/self-healing:local')
pathlib.Path(sys.argv[2]).write_text(''.join(f'{k}={v}\n' for k, v in values.items()))
PYENV
compose=(docker compose --env-file "$tmp/compose.env" -p "$prefix"
  -f "$ROOT/deploy/docker-compose.shared.yml" -f "$ROOT/deploy/docker-compose.chatwoot.yml"
  -f "$ROOT/deploy/docker-compose.dify.yml" -f "$ROOT/deploy/docker-compose.nexaduo.yml"
  -f "$ROOT/docker-compose.yml" -f "$ROOT/deploy/docker-compose.ci.yml")
# Compose omits unused volumes from normalized output; verify declaration in source.
grep -q '^  promtail-data:' "$ROOT/deploy/docker-compose.nexaduo.yml"
grep -q '^  promtail-data:' "$ROOT/docker-compose.yml"
"${compose[@]}" config --format json > "$tmp/compose.json"
jq -e --arg image "$image" '
  (.services | has("promtail") | not) and (.volumes | has("alloy-data")) and
  .services.alloy.image == $image and .services.alloy.mem_limit == "805306368" and
  .services.alloy.logging.options["max-size"] == "10m" and
  (.services.alloy.labels.autoheal // "false") != "true" and
  .services.alloy.healthcheck.test == ["CMD", "timeout", "5", "bash", "/etc/alloy/ready.sh"] and
  any(.services.alloy.volumes[]; .type == "bind" and .target == "/etc/alloy" and .read_only == true) and
  any(.services.alloy.volumes[]; .type == "volume" and .source == "alloy-data" and .target == "/var/lib/alloy")
' "$tmp/compose.json" >/dev/null
"${compose[@]}" -f "$ROOT/deploy/docker-compose.isolated.yml" config --format json |
  jq -e '(.services | has("promtail") | not) and ((.services.alloy.ports // []) | length == 0)' >/dev/null
docker pull "$image" >/dev/null
docker pull "$loki_image" >/dev/null
config=(--mount "type=bind,src=$ROOT/observability/alloy,dst=/etc/alloy,readonly")
docker run --rm --name "$verify" "${config[@]}" "$image" validate /etc/alloy/config.alloy
docker network create "$network" >/dev/null
docker run -d --name "$loki" --network "$network" --network-alias loki --user 0 \
  --publish 127.0.0.1::3100 --tmpfs /var/loki \
  --mount "type=bind,src=$ROOT/observability/loki,dst=/etc/loki,readonly" \
  "$loki_image" -config.file=/etc/loki/loki.yaml >/dev/null
url="http://$(docker port "$loki" 3100/tcp)"
# Use the pinned Alloy image's bash as the synthetic emitter too.
emit='while true; do
  echo synthetic-backlog
  echo '\''{"level":50,"msg":"synthetic alice@example.invalid +55 (11) 99999-0000 123.456.789-00","method":"POST","status":500,"trace_id":"0123456789abcdef0123456789abcdef","span_id":"0123456789abcdef","account_id":"42","conversation_id":"99"}'\''
  echo "I, [2026-09-30T00:00:00]  INFO -- : synthetic-rails" >&2
  sleep 2
done'
ids=()
for name in "$fixture" "$coolify"; do
  labels=(--label com.docker.compose.project=w2b-synthetic --label com.docker.compose.service=synthetic-compose)
  if [[ "$name" == "$coolify" ]]; then
    labels+=(--label coolify.service.subName=synthetic-coolify --label coolify.resourceName=synthetic-resource)
  fi
  ids+=("$(docker run -d --name "$name" --network "$network" "${labels[@]}" \
    --entrypoint bash "$image" -c "$emit")")
done
python3 "$ROOT/scripts/tests/alloy-docker-fixture.py" "$tmp/docker.sock" "${ids[@]}" >"$tmp/proxy.log" 2>&1 &
proxy_pid=$!
for ((i=0; i<20; i++)); do [[ ! -S "$tmp/docker.sock" ]] || break; sleep 0.1; done
# Mount a restricted socket at the normal path: the production config is unchanged.
docker run -d --name "$alloy" --network "$network" --memory 768m "${config[@]}" \
  --mount "type=bind,src=$tmp,dst=/var/run,readonly" --tmpfs /var/lib/alloy \
  "$image" run --server.http.listen-addr=0.0.0.0:12345 \
  --storage.path=/var/lib/alloy /etc/alloy/config.alloy >/dev/null
ready=0
for ((i=0; i<30; i++)); do
  if curl -fsS --max-time 1 "$url/ready" >/dev/null 2>&1 && \
    docker exec "$alloy" timeout 2 bash /etc/alloy/ready.sh 2>/dev/null; then ready=1; break; fi
  sleep 1
done
[[ "$ready" == 1 ]]
query() {
  curl -fsS --max-time 2 -G "$url/loki/api/v1/query_range" \
    --data-urlencode 'query={project="w2b-synthetic"}' --data-urlencode 'limit=1000' > "$tmp/query.json"
}
matched=0
for ((i=0; i<30; i++)); do
  if query && jq -e --arg c "$fixture" --arg k "$coolify" '
    .status == "success" and
    any(.data.result[]; .stream.container == $c and .stream.service == "synthetic-compose" and .stream.level == "ERROR") and
    any(.data.result[]; .stream.container == $k and .stream.service == "synthetic-coolify" and .stream.resource == "synthetic-resource") and
    any(.data.result[]; .stream.stream == "stderr" and .stream.level == "INFO")
  ' "$tmp/query.json" >/dev/null; then matched=1; break; fi
  sleep 1
done
[[ "$matched" == 1 ]] || { cat "$tmp/query.json"; cat "$tmp/proxy.log"; exit 1; }
# PII must not survive in any line. All four IDs remain structured metadata.
jq -e '
  [.data.result[] | select(.stream.level == "ERROR")] as $streams |
  ($streams | length > 0) and all($streams[];
    .stream.trace_id == "0123456789abcdef0123456789abcdef" and
    .stream.span_id == "0123456789abcdef" and .stream.account_id == "42" and .stream.conversation_id == "99" and
    all(.values[];
      (.[1] | contains("alice@example.invalid") or contains("99999-0000") or contains("123.456.789-00") | not) and
      (.[1] | contains("ali***@example.invalid") and contains("[PHONE]") and contains("[CPF]"))))
' "$tmp/query.json" >/dev/null
# Query responses can promote metadata to stream fields; /series is the index oracle.
curl -fsS --max-time 3 -G "$url/loki/api/v1/series" \
  --data-urlencode 'match[]={project="w2b-synthetic"}' > "$tmp/series.json"
jq -e '.status == "success" and (.data | length > 0) and
  all(.data[]; has("trace_id") or has("span_id") or has("account_id") or has("conversation_id") | not) and
  any(.data[]; .level == "ERROR" and .method == "POST" and .status == "500" and .stream == "stdout")' "$tmp/series.json" >/dev/null
# The proxy backdates the sentinel Docker frame; prove Alloy (not Loki) dropped it.
docker exec "$alloy" bash -c '
  exec 3<>/dev/tcp/127.0.0.1/12345
  printf "GET /metrics HTTP/1.0\r\nHost: localhost\r\n\r\n" >&3
  cat <&3
' > "$tmp/metrics"
awk '/^loki_process_dropped_lines_total\{/ && /reason="docker_backlog_age"/ && $NF > 0 {ok=1} END {exit !ok}' "$tmp/metrics"
jq -e 'all(.data.result[].values[]; .[1] | contains("synthetic-backlog") | not)' "$tmp/query.json" >/dev/null
# Persisted positions must exist; restart the same ephemeral container, then prove readiness.
docker exec "$alloy" test -s /var/lib/alloy/loki.source.docker.docker/positions.yml
docker restart -t 3 "$alloy" >/dev/null
for ((i=0; i<10; i++)); do
  if docker exec "$alloy" timeout 2 bash /etc/alloy/ready.sh 2>/dev/null; then break; fi
  sleep 1
done
docker exec "$alloy" timeout 2 bash /etc/alloy/ready.sh
# Fresh entries after restart prove the pipeline resumed, not merely the UI.
restart_ns=$(date +%s%N)
resumed=0
for ((i=0; i<10; i++)); do
  if query && jq -e --argjson since "$restart_ns" '
    any(.data.result[].values[]; (.[0] | tonumber) > $since)
  ' "$tmp/query.json" >/dev/null; then resumed=1; break; fi
  sleep 1
done
[[ "$resumed" == 1 ]]
echo 'PASS: compose coverage, real config, readiness, Compose/Coolify labels, stdout/stderr, PII masks, structured IDs (not indexed), backlog age guard, positions and restart'
