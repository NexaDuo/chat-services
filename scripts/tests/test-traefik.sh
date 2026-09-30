#!/usr/bin/env bash
# Synthetic #151 regression: real proxy config, no tunnel, published ports or volumes.
# Requires Docker Compose, jq and GNU timeout. Internal infra: Playwright N/A.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ ${1:-} != --bounded ]]; then
  # Includes pulls/startup/probes; reserve 10 seconds for EXIT cleanup.
  exec timeout --signal=TERM --kill-after=10s 105s bash "$0" --bounded
fi
prefix="w1b-traefik-$(cat /proc/sys/kernel/random/uuid)"
proxy="$prefix-proxy"
fixture="$prefix-fixture"
network="$prefix-net"
cleanup() {
  local status=$?
  trap - EXIT
  timeout 5s docker rm -f "$proxy" "$fixture" >/dev/null 2>&1 || true
  timeout 3s docker network rm "$network" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Explicit file/env options prevent reading the host .env or inherited CI chain.
config=$(docker compose --env-file /dev/null -p "$prefix" \
  -f "$ROOT/deploy/docker-compose.localproxy.yml" config --format json)
image=$(jq -er '.services["coolify-proxy"].image' <<<"$config")
# Any digest-pinned v3 (the exact tag lives only in the compose file).
[[ $image =~ ^traefik:v3\.[0-9]+\.[0-9]+@sha256:[a-f0-9]{64}$ ]]
mapfile -t args < <(jq -r '.services["coolify-proxy"].command[]' <<<"$config")
# Only the network changes; constrain discovery to this fixture on shared daemons.
for i in "${!args[@]}"; do
  if [[ ${args[$i]} == --providers.docker.network=* ]]; then
    args[$i]="--providers.docker.network=$network"
  fi
done
args+=("--providers.docker.constraints=Label(\`w1b.fixture\`, \`$prefix\`)")

docker pull "$image" >/dev/null
docker network create "$network" >/dev/null
# Reuse the pinned Traefik image's BusyBox nc server as a tiny echo fixture.
# No additional image or host bind mount, and only synthetic header contents.
docker run -d --name "$fixture" --network "$network" --restart=no \
  --label traefik.enable=true --label "w1b.fixture=$prefix" \
  --label "traefik.http.routers.$prefix.rule=Host(\`$prefix.invalid\`)" \
  --label "traefik.http.routers.$prefix.entrypoints=http" \
  --label "traefik.http.routers.$prefix.service=$prefix" \
  --label "traefik.http.services.$prefix.loadbalancer.server.port=8000" \
  --entrypoint /bin/sh "$image" -c "$(cat <<'FIXTURE'
cat > /tmp/echo-http <<'HANDLER'
#!/bin/sh
headers=""
while IFS= read -r line; do
  line=$(printf '%s' "$line" | tr -d '\r')
  [ -n "$line" ] || break
  headers="$headers$line
"
done
printf 'HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nConnection: close\r\n\r\n%s' "$headers"
HANDLER
chmod +x /tmp/echo-http
exec nc -lk -p 8000 -e /tmp/echo-http
FIXTURE
)" >/dev/null
docker run -d --name "$proxy" --network "$network" --restart=no \
  --mount type=bind,src=/var/run/docker.sock,dst=/var/run/docker.sock,readonly \
  --mount "type=bind,src=$ROOT/deploy/traefik,dst=/etc/traefik/dynamic,readonly" \
  "$image" "${args[@]}" >/dev/null

ready=false
for ((i=0; i<30; i++)); do
  if routers=$(docker exec "$proxy" wget -qO- -T 2 http://127.0.0.1:8080/api/http/routers) &&
    jq -e --arg name "$prefix@docker" \
      'any(.[]; .name == $name and .provider == "docker" and .status == "enabled")' \
      <<<"$routers" >/dev/null; then
    ready=true
    break
  fi
  sleep 1
done
if [[ $ready != true ]]; then
  docker logs "$proxy" >&2
  echo 'FAIL: fixture Docker router did not become enabled' >&2
  exit 1
fi
echo 'PASS: fixture router enabled via Docker provider (internal API)'

# Demand an HTTP 403, not merely wget failure (DNS/connection failures must fail).
# Also prove a forged forwarded loopback address cannot bypass ipAllowList.
for forwarded in 192.0.2.1 127.0.0.1; do
  if response=$(docker exec "$fixture" wget -S -O- -T 3 \
    --header "X-Forwarded-For: $forwarded" "http://$proxy:8080/api/http/routers" 2>&1); then
    echo 'FAIL: neighbour could read API' >&2
    exit 1
  fi
  [[ $response == *'HTTP/1.1 403 Forbidden'* ]]
done
echo 'PASS: neighbour API requests denied with 403'

body=$(docker exec "$fixture" wget -qO- -T 3 \
  --header "Host: $prefix.invalid" --header 'api_access_token: synthetic-w1b' \
  "http://$proxy/cgi-bin/echo")
grep -qi '^api_access_token: synthetic-w1b' <<<"$body"
echo 'PASS: Host routing and underscore authentication header preserved'
