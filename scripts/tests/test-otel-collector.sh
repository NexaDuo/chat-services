#!/usr/bin/env bash
# W2c: synthetic old/new OTLP contract; isolated from Compose and production.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ${1:-} != --bounded ]]; then
  exec timeout --signal=TERM --kill-after=10s 105s bash "$0" --bounded
fi
prefix="w2c-otel-$(cat /proc/sys/kernel/random/uuid)"
network="$prefix-net"; collector="$prefix-new"; old="$prefix-old"
tempo="$prefix-tempo"; probe="$prefix-probe"; verify="$prefix-validate"
tmp=$(mktemp -d)
cleanup() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    for name in "$collector" "$old" "$tempo"; do timeout 1s docker logs --tail 30 "$name" 2>&1 || true; done
  fi
  timeout 4s docker rm -fv "$collector" "$old" "$tempo" "$probe" "$verify" >/dev/null 2>&1 || true
  timeout 2s docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
image=$(sed -n 's/^    image: \(otel\/opentelemetry-collector-contrib:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $image =~ ^otel/opentelemetry-collector-contrib:0\.[^@]+@sha256:[a-f0-9]{64}$ ]]
tempo_image=$(sed -n 's/^    image: \(grafana\/tempo:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
old_image=otel/opentelemetry-collector-contrib:0.111.0@sha256:a2a52e43c1a80aa94120ad78c2db68780eb90e6d11c8db5b3ce2f6a0cc6b5029
probe_image=alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507
for img in "$image" "$old_image" "$tempo_image" "$probe_image"; do docker pull "$img" >/dev/null; done
config=(--mount "type=bind,src=$ROOT/observability/otel-collector/config.yaml,dst=/etc/otel.yaml,readonly")
docker run --rm --name "$verify" "${config[@]}" "$image" validate --config=/etc/otel.yaml
# Historical config differs only by the new translation key. /health is supported
# by both. Keep the baseline independent of the target's naming configuration.
sed '/^[[:space:]]*translation_strategy:/d' "$ROOT/observability/otel-collector/config.yaml" > "$tmp/old.yaml"
docker network create "$network" >/dev/null
docker run -d --name "$probe" --network "$network" "$probe_image" sleep 110 >/dev/null
# Tempo storage is disposable tmpfs, never a production or persistent volume.
docker run -d --name "$tempo" --network "$network" --network-alias tempo \
  --user 0 --tmpfs /var/tempo --publish 127.0.0.1::3200 \
  --mount "type=bind,src=$ROOT/observability/tempo/tempo.yaml,dst=/etc/tempo.yaml,readonly" \
  "$tempo_image" -config.file=/etc/tempo.yaml >/dev/null
tempo_url="http://$(docker port "$tempo" 3200/tcp)"
for name in "$old" "$collector"; do
  img=$image
  mounts=("${config[@]}")
  if [[ $name == "$old" ]]; then
    img=$old_image
    mounts=(--mount "type=bind,src=$tmp/old.yaml,dst=/etc/otel.yaml,readonly")
  fi
  docker run -d --name "$name" --network "$network" \
    --publish 127.0.0.1::4318 --publish 127.0.0.1::8889 \
    "${mounts[@]}" "$img" --config=/etc/otel.yaml >/dev/null
  for ((i=0; i<20; i++)); do
    if docker exec "$probe" wget -qO- -T 2 "http://$name:13133/health" >/dev/null 2>&1; then break; fi
    sleep 1
  done
  docker exec "$probe" wget -qO- -T 2 "http://$name:13133/health" >/dev/null
  python3 "$ROOT/scripts/tests/otel-collector-fixture.py" \
    "http://$(docker port "$name" 4318/tcp)" \
    "http://$(docker port "$name" 8889/tcp)" "$tempo_url" "$tmp/$name.scrape"
done
diff -u "$tmp/$old.scrape" "$tmp/$collector.scrape"
echo 'PASS: config validation, sibling /health, identical old/new metric names/types/labels/timestamps and terminal Tempo traces'
