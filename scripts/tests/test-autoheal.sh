#!/usr/bin/env bash
# Synthetic Docker health/restart regression; no Compose, secrets or data volumes.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Bound pulls, Docker calls and polling, leaving five seconds for cleanup.
if [[ ${1:-} != --bounded ]]; then
  exec timeout --signal=TERM --kill-after=5s 75s bash "$0" --bounded
fi
prefix="w1a-autoheal-$(cat /proc/sys/kernel/random/uuid)"
watcher="$prefix-watcher"
fixture="$prefix-fixture"
selector="$prefix"
cleanup() {
  timeout 4s docker rm -f "$watcher" "$fixture" >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Read the production pin directly so CI cannot silently test a different image.
image=$(awk '/^  autoheal:$/ {service=1; next} service && /^    image:/ {print $2; exit}' \
  "$ROOT/deploy/docker-compose.shared.yml")
[[ $image =~ ^willfarrell/autoheal:1\.2\.0@sha256:[a-f0-9]{64}$ ]]
docker pull "$image" >/dev/null

# Use the same image's shell for the fixture; its main process never exits.
# A unique additional label confines THIS watcher to THIS run, even on a shared
# daemon. autoheal=true preserves the production opt-in contract. Existing host
# watchers may see the fixture, so success also requires our watcher's log.
docker run -d --name "$fixture" --network none --restart=no \
  --label autoheal=true --label "$selector=true" \
  --health-cmd 'exit 1' --health-interval 1s --health-timeout 1s \
  --health-retries 1 --health-start-period 0s --entrypoint /bin/sh \
  "$image" -c 'while :; do sleep 3600; done' >/dev/null
before=$(docker inspect --format '{{.State.StartedAt}}' "$fixture")
# Wait for an actual unhealthy state before introducing the watcher.
for ((i=0; i<15; i++)); do
  health=$(docker inspect --format '{{.State.Health.Status}}' "$fixture")
  [[ $health == unhealthy ]] && break
  sleep 1
done
[[ $health == unhealthy ]]
docker run -d --name "$watcher" --network none --restart=no \
  -e "AUTOHEAL_CONTAINER_LABEL=$selector" -e AUTOHEAL_INTERVAL=1 \
  -e AUTOHEAL_START_PERIOD=0 -e AUTOHEAL_DEFAULT_STOP_TIMEOUT=1 \
  -e CURL_TIMEOUT=3 --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock \
  "$image" >/dev/null

for ((i=0; i<25; i++)); do
  after=$(docker inspect --format '{{.State.StartedAt}}' "$fixture")
  logs=$(docker logs "$watcher" 2>&1)
  if [[ $after != "$before" && $logs == *"/$fixture "*"Restarting container now"* && $logs != *"failed"* ]]; then
    echo "PASS: pinned autoheal detected unhealthy fixture and restarted it"
    exit 0
  fi
  sleep 1
done
docker logs "$watcher" >&2
echo 'FAIL: no successful autoheal restart observed' >&2
exit 1
