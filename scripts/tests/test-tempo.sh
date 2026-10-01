#!/usr/bin/env bash
# W4a: only synthetic data and uniquely named throwaway Docker resources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image=$(sed -n 's/^    image: \(grafana\/tempo:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $image =~ ^grafana/tempo:[0-9]+\.[^@]+@sha256:[a-f0-9]{64}$ ]]
old_image=grafana/tempo:2.6.1@sha256:ef4384fce6e8ad22b95b243d8fc165628cda655376fd50e7850536ad89d71d50
probe_image=alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507
# Network pulls are outside the bounded test, including on cold CI runners.
if [[ ${1:-} != --bounded ]]; then
  for img in "$image" "$old_image" "$probe_image"; do docker pull "$img" >/dev/null; done
  exec timeout --signal=TERM --kill-after=15s 130s bash "$0" --bounded
fi
prefix="w4a-tempo-$(cat /proc/sys/kernel/random/uuid)"
old="$prefix-old"; new="$prefix-new"; probe="$prefix-probe"
volume="$prefix-data"; network="$prefix-net"
tmp=$(mktemp -d)
cleanup() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    for name in "$old" "$new"; do timeout 2s docker logs --tail 35 "$name" 2>&1 || true; done
  fi
  timeout 5s docker rm -fv "$old" "$new" "$probe" >/dev/null 2>&1 || true
  timeout 3s docker volume rm "$volume" >/dev/null 2>&1 || true
  timeout 3s docker network rm "$network" >/dev/null 2>&1 || true
  rm -rf "$tmp"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
source "$ROOT/scripts/lib/tempo-ready.sh"
# Read the actual Compose user so a future permission regression fails this test.
user=$(sed -n '/^  tempo:/,/^volumes:/s/^    user: "\([^"]*\)"/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $user == 0 ]]
docker network create "$network" >/dev/null
docker volume create "$volume" >/dev/null
docker run -d --name "$probe" --network "$network" -v "$volume:/data:ro" "$probe_image" sleep 145 >/dev/null
start() {
  docker run -d --name "$1" --network "$network" --network-alias tempo \
    --user "$user" -v "$volume:/var/tempo" --publish 127.0.0.1::3200 --publish 127.0.0.1::4318 \
    --mount "type=bind,src=$ROOT/observability/tempo/tempo.yaml,dst=/etc/tempo.yaml,readonly" \
    "$2" -config.file=/etc/tempo.yaml >/dev/null
  for ((i=0; i<80; i++)); do
    if tempo_ready "$probe"; then break; fi
    sleep 0.5
  done
  tempo_ready "$probe"
}
start "$old" "$old_image"
python3 "$ROOT/scripts/tests/tempo-fixture.py" write "$old" "$tmp/old.json"
# Require an actual backend block before stopping, not just a WAL replay.
blocks() { docker exec "$probe" find /data/blocks -name meta.json; }
for ((i=0; i<30; i++)); do [[ -n $(blocks) ]] && break; sleep 0.5; done
[[ -n $(blocks) ]]
blocks > "$tmp/old-blocks"
docker stop -t 5 "$old" >/dev/null
docker network disconnect "$network" "$old"
start "$new" "$image"
python3 "$ROOT/scripts/tests/tempo-fixture.py" read "$new" "$tmp/old.json"
python3 "$ROOT/scripts/tests/tempo-fixture.py" write "$new" "$tmp/new.json"
for ((i=0; i<30; i++)); do
  blocks > "$tmp/new-blocks"
  comm -13 <(sort "$tmp/old-blocks") <(sort "$tmp/new-blocks") > "$tmp/added"
  [[ -s "$tmp/added" ]] && break
  sleep 0.5
done
[[ -s "$tmp/added" ]]
while IFS= read -r meta; do
  docker exec "$probe" cat "$meta" | python3 -c 'import json,sys; m = json.load(sys.stdin); assert m.get("format") == "vParquet4", m'
  [[ $(docker exec "$probe" stat -c %u "$meta") == 0 ]]
done < "$tmp/added"
tempo_ready "$probe"
echo 'PASS: old persisted trace, new OTLP trace + TraceQL, /api/echo probe, vParquet4 blocks and root-owned volume reuse'
