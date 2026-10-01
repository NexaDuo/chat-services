#!/usr/bin/env bash
# W3a: real config, synthetic 2.x blocks -> 3.x scrapes/WAL -> 2.x rollback.
# No Compose calls or production resources. Pulls precede the bounded test.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image=$(sed -n 's/^    image: \(prom\/prometheus:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $image =~ ^prom/prometheus:v3\.[^@]+@sha256:[a-f0-9]{64}$ ]]
old_image=prom/prometheus:v2.55.0@sha256:378f4e03703557d1c6419e6caccf922f96e6d88a530f7431d66a4c4f4b1000fe
fixture_image=python:3.12-alpine@sha256:4c47124a8391cb7a9f571164147d154777cf012a4ece5f86097130d7a4478111
if [[ ${1:-} != --bounded ]]; then
  for img in "$image" "$old_image" "$fixture_image"; do docker pull "$img" >/dev/null; done
  exec timeout --signal=TERM --kill-after=10s 105s bash "$0" --bounded
fi
SECONDS=0
prefix="w3a-prom-$(cat /proc/sys/kernel/random/uuid)"
old="$prefix-old"; new="$prefix-new"; fixture="$prefix-fixture"
verify="$prefix-verify"; seed="$prefix-seed"
volume="$prefix-data"; network="$prefix-net"
tmp=$(mktemp -d)
cleanup() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    for name in "$old" "$new"; do timeout 1s docker logs --tail 25 "$name" 2>&1 || true; done
  fi
  timeout 4s docker rm -fv "$old" "$new" "$fixture" "$verify" "$seed" >/dev/null 2>&1 || true
  timeout 2s docker volume rm "$volume" >/dev/null 2>&1 || true
  timeout 2s docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Validate the unmodified repository config with the exact deployment image.
docker run --rm --name "$verify" --entrypoint promtool \
  --mount "type=bind,src=$ROOT/observability/prometheus,dst=/etc/prometheus,readonly" \
  "$image" check config /etc/prometheus/prometheus.yml
# Only accelerate intervals; retain actual jobs, targets and labeldrop.
sed -e 's/scrape_interval: 15s/scrape_interval: 1s/' \
  -e 's/evaluation_interval: 15s/evaluation_interval: 1s/' \
  "$ROOT/observability/prometheus/prometheus.yml" > "$tmp/new.yml"
sed '/metric_name_validation_scheme:/d' "$tmp/new.yml" > "$tmp/old.yml"
# Older than the head window: proves persisted blocks, not just recent samples.
stamp=$(( $(date +%s) - 14400 ))
{
  echo '# TYPE historical_tokens counter'
  for i in {0..9}; do
    echo "historical_tokens_total{account_id=\"historical\"} $((100 + i * 10)) $((stamp + i * 15))"
  done
  echo '# EOF'
} > "$tmp/samples.om"
chmod 755 "$tmp"
chmod 644 "$tmp/"*
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run --rm --name "$seed" --user 0 --entrypoint promtool \
  --mount "type=bind,src=$tmp,dst=/fixture,readonly" \
  --mount "type=volume,src=$volume,dst=/prometheus" \
  "$old_image" tsdb create-blocks-from openmetrics /fixture/samples.om /prometheus/data
# promtool ran as root; test processes use root only on this throwaway volume.
docker run -d --name "$fixture" --network "$network" \
  --network-alias middleware --network-alias otel-collector \
  --mount "type=bind,src=$ROOT/scripts/tests/prometheus-fixture.py,dst=/fixture.py,readonly" \
  "$fixture_image" python /fixture.py >/dev/null
start() {
  docker run -d --name "$1" --user 0 --network "$network" \
    --publish 127.0.0.1::9090 \
    --mount "type=bind,src=$tmp/$3.yml,dst=/etc/prometheus/prometheus.yml,readonly" \
    --mount "type=volume,src=$volume,dst=/prometheus" "$2" \
    --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.retention.time=30d >/dev/null
  url="http://$(docker port "$1" 9090/tcp)"
  for ((i=0; i<20; i++)); do
    if curl -fsS --max-time 2 "$url/-/ready" >/dev/null 2>&1; then return; fi
    sleep 1
  done
  return 1
}
query() {
  curl -fsS --max-time 3 -G "$url/api/v1/query" --data-urlencode "query=$1" "${@:2}"
}
history() {
  query 'historical_tokens_total{account_id="historical"}' \
    --data-urlencode "time=$((stamp + 135))" |
    jq -e '.status == "success" and (.data.result | length == 1) and .data.result[0].value[1] == "190"' >/dev/null
}
start "$old" "$old_image" old
history
docker stop -t 5 "$old" >/dev/null
docker rm "$old" >/dev/null
start "$new" "$image" new
history
# Same command as the production Docker healthcheck (wget exists in this image).
docker exec "$new" wget -qO- -T 5 http://127.0.0.1:9090/-/healthy >/dev/null
for ((i=0; i<20; i++)); do
  if query 'sum by (account_id) (increase(middleware_dify_tokens_total[1h]))' |
    jq -e 'any(.data.result[]; .metric.account_id == "synthetic" and (.value[1] | tonumber) > 0)' >/dev/null; then break; fi
  sleep 1
done
query 'sum by (account_id) (increase(middleware_dify_tokens_total[1h]))' |
  jq -e 'any(.data.result[]; .metric.account_id == "synthetic" and (.value[1] | tonumber) > 0)' >/dev/null
query 'up' | jq -e '(.data.result | length == 3) and all(.data.result[]; .value[1] == "1")' >/dev/null
query 'middleware_dify_request_duration_seconds_bucket{job="dify-api",le="1.0"}' |
  jq -e '(.data.result | length == 1) and all(.data.result[].metric | keys[]; startswith("otel_scope_") | not)' >/dev/null
query 'histogram_quantile(0.50, sum(rate(middleware_dify_request_duration_seconds_bucket[5m])) by (le))' |
  jq -e '(.data.result | length == 1) and (.data.result[0].value[1] | tonumber) > 0' >/dev/null
# Exercise the exact provisioned token alert expressions as well.
while IFS= read -r expr; do
  query "$expr" | jq -e '.status == "success" and (.data.result | length > 0) and all(.data.result[]; (.value[1] | tonumber) > 0)' >/dev/null
done < <(sed -n 's/^ *expr: //p' "$ROOT/observability/grafana/provisioning/alerting/dify-token-usage.yml")
# Preserve a timestamp to prove 2.55 reads samples written by 3.x's WAL.
rollback_time=$(date +%s)
docker stop -t 5 "$new" >/dev/null
docker rm "$new" >/dev/null
start "$old" "$old_image" old
history
query 'middleware_dify_tokens_total{job="dify-api",account_id="synthetic"}' \
  --data-urlencode "time=$rollback_time" |
  jq -e '(.data.result | length == 1) and (.data.result[0].value[1] | tonumber) > 0' >/dev/null
echo "PASS (${SECONDS}s): config, healthcheck, 2.55 blocks, 3.x scrapes/alerts/histograms/labeldrop, 2.55 rollback including 3.x WAL"
