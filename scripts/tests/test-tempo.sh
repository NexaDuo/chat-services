#!/usr/bin/env bash
# W4b: only synthetic data and uniquely named throwaway Docker resources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
image=$(sed -n 's/^    image: \(grafana\/tempo:.*\)$/\1/p' "$ROOT/deploy/docker-compose.nexaduo.yml")
[[ $image =~ ^grafana/tempo:3\.[^@]+@sha256:[a-f0-9]{64}$ ]]
bridge_image=grafana/tempo:2.10.8@sha256:f0561deb1c68ec44d6e6e7e4487f30106c4e5e768642077695b37958b105812a
old_image=grafana/tempo:2.6.1@sha256:ef4384fce6e8ad22b95b243d8fc165628cda655376fd50e7850536ad89d71d50
probe_image=alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
# Network pulls are outside the bounded test, including on cold CI runners.
if [[ ${1:-} != --bounded ]]; then
  for img in "$image" "$old_image" "$bridge_image" "$probe_image"; do docker pull "$img" >/dev/null; done
  exec timeout --signal=TERM --kill-after=15s 180s bash "$0" --bounded
fi
prefix="w4b-tempo-$(cat /proc/sys/kernel/random/uuid)"
bridge="$prefix-bridge"; old="$prefix-old"; new="$prefix-new"; probe="$prefix-probe"
volume="$prefix-data"; network="$prefix-net"
tmp=$(mktemp -d)
cleanup() {
  status=$?
  trap - EXIT
  if (( status != 0 )); then
    for name in "$old" "$bridge" "$new"; do timeout 1s docker logs --tail 35 "$name" 2>&1 || true; done
  fi
  timeout 4s docker rm -fv "$old" "$bridge" "$new" "$probe" >/dev/null 2>&1 || true
  timeout 2s docker volume rm "$volume" >/dev/null 2>&1 || true
  timeout 2s docker network rm "$network" >/dev/null 2>&1 || true
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
docker run -d --name "$probe" --network "$network" -v "$volume:/data:ro" "$probe_image" sleep 195 >/dev/null
start() {
  docker run -d --name "$1" --network "$network" --network-alias tempo \
    --user "$user" -v "$volume:/var/tempo" --publish 127.0.0.1::3200 --publish 127.0.0.1::4318 \
    --mount "type=bind,src=$ROOT/$3,dst=/etc/tempo.yaml,readonly" \
    "$2" -config.file=/etc/tempo.yaml >/dev/null
  for ((i=0; i<80; i++)); do
    if tempo_ready "$probe"; then break; fi
    sleep 0.5
  done
  tempo_ready "$probe"
}
start "$old" "$old_image" scripts/tests/tempo-2x.yaml
python3 "$ROOT/scripts/tests/tempo-fixture.py" write "$old" "$tmp/old.json"
# Require an actual backend block before stopping, not just a WAL replay.
blocks() { docker exec "$probe" find /data/blocks -name meta.json; }
for ((i=0; i<30; i++)); do [[ -n $(blocks) ]] && break; sleep 0.5; done
[[ -n $(blocks) ]]
blocks > "$tmp/old-blocks"
docker stop -t 5 "$old" >/dev/null
docker network disconnect "$network" "$old"
start "$bridge" "$bridge_image" scripts/tests/tempo-2x.yaml
python3 "$ROOT/scripts/tests/tempo-fixture.py" write "$bridge" "$tmp/bridge.json"
for ((i=0; i<30; i++)); do
  [[ $(blocks | wc -l) -gt $(wc -l < "$tmp/old-blocks") ]] && break
  sleep 0.5
done
[[ $(blocks | wc -l) -gt $(wc -l < "$tmp/old-blocks") ]]
docker stop -t 5 "$bridge" >/dev/null
docker network disconnect "$network" "$bridge"
blocks > "$tmp/old-blocks"
start "$new" "$image" observability/tempo/tempo.yaml
python3 "$ROOT/scripts/tests/tempo-fixture.py" read "$new" "$tmp/bridge.json"
python3 "$ROOT/scripts/tests/tempo-fixture.py" read "$new" "$tmp/old.json"
t0=$(date -u +%Y-%m-%dT%H:%M:%S)
python3 "$ROOT/scripts/tests/tempo-fixture.py" write3 "$new" "$tmp/new.json"
# 3.0 removed /flush: wait for the real config to persist a backend block that
# covers the new trace. A block compacted from the 2.x ones ends before t0 and
# must not count, or the kill below would only prove WAL replay.
fresh() {
  docker exec "$probe" cat "$1" 2>/dev/null |
    python3 -c 'import json,sys; m = json.load(sys.stdin); sys.exit(m["endTime"][:19] < sys.argv[1])' "$t0" 2>/dev/null
}
: > "$tmp/added"
for ((i=0; i<120; i++)); do
  blocks > "$tmp/new-blocks"
  while IFS= read -r meta; do
    if fresh "$meta"; then echo "$meta" >> "$tmp/added"; fi
  done < <(comm -13 <(sort "$tmp/old-blocks") <(sort "$tmp/new-blocks"))
  [[ -s "$tmp/added" ]] && break
  sleep 0.5
done
[[ -s "$tmp/added" ]]
while IFS= read -r meta; do
  docker exec "$probe" cat "$meta" | python3 -c 'import json,sys; m = json.load(sys.stdin); assert int(m["format"].removeprefix("vParquet")) >= 4, m'
  [[ $(docker exec "$probe" stat -c %u "$meta") == 0 ]]
done < "$tmp/added"
# Abrupt restart after backend persistence, not just a graceful WAL flush.
docker kill "$new" >/dev/null
docker start "$new" >/dev/null
python3 "$ROOT/scripts/tests/tempo-fixture.py" read "$new" "$tmp/new.json"
python3 "$ROOT/scripts/tests/tempo-fixture.py" read "$new" "$tmp/old.json"
python3 "$ROOT/scripts/tests/tempo-fixture.py" read "$new" "$tmp/bridge.json"
tempo_ready "$probe"
docker logs "$new" > "$tmp/tempo.log" 2>&1
if grep -Ei 'level=error.*(blocklist|unknown block|poll)' "$tmp/tempo.log"; then
  exit 1
fi
grep -F 'msg="retention provider started"' "$tmp/tempo.log"
for component in backend-scheduler backend-worker; do
  grep -E "msg=starting module=$component" "$tmp/tempo.log"
done
echo 'PASS: 2.6.1 → 2.10.8 → 3.x persisted traces, TraceQL, restart, probe, block format and maintenance services'
