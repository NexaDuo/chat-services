#!/usr/bin/env bash
# Synthetic 3.2 -> pinned 3.x storage/readiness regression; no production resources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ${1:-} != --bounded ]]; then
  exec timeout --signal=TERM --kill-after=10s 75s bash "$0" --bounded
fi
prefix="w2a-loki-$(cat /proc/sys/kernel/random/uuid)"
old="$prefix-old"; new="$prefix-new"; probe="$prefix-probe"
volume="$prefix-data"; network="$prefix-net"; verify="$prefix-verify"
cleanup() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then docker logs "$new" 2>&1 || true; fi
  timeout 5s docker rm -f "$old" "$new" "$probe" "$verify" >/dev/null 2>&1 || true
  timeout 2s docker volume rm "$volume" >/dev/null 2>&1 || true
  timeout 2s docker network rm "$network" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source "$ROOT/scripts/lib/loki-ready.sh"
image=$(sed -n 's/^    image: \(grafana\/loki:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $image =~ ^grafana/loki:3\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}$ ]]
# Historical fixture pin, deliberately independent of the deployment target.
old_image=grafana/loki:3.2.0@sha256:882e30c20683a48a8b7ca123e6c19988980b4bd13d2ff221dfcbef0fdc631694
docker pull "$image" >/dev/null
docker pull "$old_image" >/dev/null
config=(--mount "type=bind,src=$ROOT/observability/loki,dst=/etc/loki,readonly")
docker run --rm --name "$verify" "${config[@]}" "$image" \
  -config.file=/etc/loki/loki.yaml -config.expand-env=true -verify-config
echo 'PASS: pinned Loki accepts repository config'
# Upgrade review: https://grafana.com/docs/loki/latest/setup/upgrade/
# No removed local keys; no Bloom, S3 SDK or opt-in Thanos storage in use.
# Preserve TSDB/filesystem/v13 and its 2020 period. table_manager does not
# enforce TSDB retention: compactor.retention_enabled remains false in both
# versions. Do not turn on deletion as a side effect of this image upgrade.
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
# The old image supplies wget with the probe flags also supported by middleware.
docker run -d --name "$probe" --network "$network" --entrypoint /bin/sh \
  "$old_image" -c 'sleep 80' >/dev/null
start() {
  docker run -d --name "$1" --network "$network" --network-alias loki \
    --user 0 --publish 127.0.0.1::3100 "${config[@]}" \
    --mount "type=volume,src=$volume,dst=/var/loki" "$2" \
    -config.file=/etc/loki/loki.yaml >/dev/null
  url="http://$(docker port "$1" 3100/tcp)"
  for ((i=0; i<20; i++)); do
    if loki_ready "$probe"; then return; fi
    sleep 1
  done
  echo 'FAIL: external readiness' >&2; return 1
}
# Four hours old forces the post-upgrade query beyond query_ingesters_within
# (3h default): this checks persisted TSDB/chunks, not just replayed WAL memory.
stamp=$(( $(date +%s%N) - 4 * 3600 * 1000000000 ))
start_ns=$((stamp - 1000000000))
push() {
  local body code
  body=$(jq -nc --arg t "$stamp" --arg line "$1" \
    '{streams:[{stream:{job:"w2a-synthetic"},values:[[$t,$line,{fixture_id:"synthetic"}]]}]}')
  code=$(curl -sS --max-time 5 -o /dev/null -w '%{http_code}' \
    -H 'Content-Type: application/json' --data "$body" "$url/loki/api/v1/push")
  [[ $code == 204 ]]
}
query() {
  local end
  end=$(date +%s%N)
  [[ $1 != before-upgrade ]] || end=$((start_ns + 2000000000))
  curl -fsS --max-time 5 -G "$url/loki/api/v1/query_range" \
    --data-urlencode 'query={job="w2a-synthetic"} | fixture_id="synthetic"' \
    --data-urlencode "start=$start_ns" --data-urlencode "end=$end" |
    jq -e --arg line "$1" '.status == "success" and any(.data.result[]; .stream.job == "w2a-synthetic" and any(.values[]; .[1] == $line))' >/dev/null
}
start "$old" "$old_image"
push before-upgrade
# Flush TSDB chunks/index to the disposable volume, then remove the old process.
curl -fsS --max-time 5 -X POST "$url/flush" >/dev/null
docker stop -t 5 "$old" >/dev/null
docker rm "$old" >/dev/null
start "$new" "$image"
query before-upgrade
stamp=$(date +%s%N)
push after-upgrade
query after-upgrade
# Readiness must fail closed for an HTTP error too, not merely a dead process.
if loki_ready "$probe" http://loki:3100/not-a-ready-endpoint; then
  echo 'FAIL: readiness accepted HTTP 404' >&2; exit 1
fi
echo 'PASS: external readiness, HTTP failure, persisted old logs, new push/query_range and metadata filter'
