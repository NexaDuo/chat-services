#!/usr/bin/env bash
# W7a: build and exercise the committed policy without .env or live resources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export SQUID_TEST_ROOT="$ROOT"
export COMPOSE_PROJECT_NAME="w7a-squid-$(cat /proc/sys/kernel/random/uuid)"
work=$(mktemp -d)
export COMPOSE_FILE="$work/compose.yml" COMPOSE_ENV_FILES=/dev/null COMPOSE_DISABLE_ENV_FILE=1
export SQUID_TEST_IMAGE="$COMPOSE_PROJECT_NAME:proxy"
fixture_image="$COMPOSE_PROJECT_NAME:fixture"
cleanup() {
  local status=$?
  trap - EXIT
  timeout 12s docker compose --env-file /dev/null down --timeout 1 >/dev/null 2>&1 || true
  timeout 5s docker image rm "$SQUID_TEST_IMAGE" "$fixture_image" >/dev/null 2>&1 || true
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

docker build -t "$SQUID_TEST_IMAGE" "$ROOT/deploy/squid"
cat > "$work/Dockerfile" <<'DOCKER'
FROM alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6
RUN apk add --no-cache python3 curl openssl \
    && openssl req -x509 -newkey rsa:2048 -nodes -days 2 \
       -keyout /fixture.key -out /fixture.crt -subj /CN=example.com \
       -addext subjectAltName=DNS:example.com
COPY server.py /server.py
ENV CURL_CA_BUNDLE=/fixture.crt
CMD ["python3", "/server.py"]
DOCKER
cat > "$work/server.py" <<'PY'
import http.server
import ssl
import threading

http.server.ThreadingHTTPServer.request_queue_size = 64

class Handler(http.server.BaseHTTPRequestHandler):
    # Content-Length lets curl finish before the TLS socket closes without
    # close_notify, which OpenSSL 3 reports as an unexpected EOF.
    def reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):
        self.reply(200, b"public fixture\n")

    def do_POST(self):
        self.reply(401, b'{"error":"unauthorized"}')

    def log_message(self, *_):
        pass

for port in (80, 4000, 443):
    server = http.server.ThreadingHTTPServer(("0.0.0.0", port), Handler)
    if port == 443:
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
        context.load_cert_chain("/fixture.crt", "/fixture.key")
        # Handshake in the per-connection thread, not serially inside accept().
        server.socket = context.wrap_socket(server.socket, server_side=True,
                                            do_handshake_on_connect=False)
    threading.Thread(target=server.serve_forever, daemon=True).start()
threading.Event().wait()
PY
docker build -t "$fixture_image" "$work"
# A globally-shaped subnet is confined to an internal bridge (no public egress).
# Randomize it as well as the project; overlap causes a safe startup failure.
# The static address sits above the range dynamic allocation hands out first.
subnet="11.$((RANDOM % 250 + 1)).$((RANDOM % 250 + 1))"
cat > "$COMPOSE_FILE" <<YAML
services:
  dify-ssrf-proxy:
    image: $SQUID_TEST_IMAGE
    volumes:
      - $ROOT/deploy/squid/squid.conf:/etc/squid/squid.conf:ro
    mem_limit: 128m
    networks: [private, public]
  external:
    image: $fixture_image
    networks:
      public:
        ipv4_address: $subnet.200
        aliases: [example.com]
  middleware:
    image: $fixture_image
    networks:
      private:
        aliases: [postgres]
  dify-api:
    image: $fixture_image
    command: [sleep, infinity]
    environment: &proxy-env
      SSRF_PROXY_HTTP_URL: http://dify-ssrf-proxy:3128
      SSRF_PROXY_HTTPS_URL: http://dify-ssrf-proxy:3128
      HTTP_PROXY: http://dify-ssrf-proxy:3128
      HTTPS_PROXY: http://dify-ssrf-proxy:3128
      NO_PROXY: ''
      no_proxy: ''
    networks: [private]
  dify-worker:
    image: $fixture_image
    command: [sleep, infinity]
    environment: *proxy-env
    networks: [private]
  dify-sandbox:
    image: $fixture_image
    command: [sleep, infinity]
    environment: *proxy-env
    networks: [private]
networks:
  private:
    internal: true
  public:
    internal: true
    ipam:
      config:
        - subnet: $subnet.0/24
YAML
# A file, not stdin: `docker compose exec -T` would swallow the rest of a
# heredoc-fed script and bash would exit 0 at the first exec (vacuous pass).
cat > "$work/test.sh" <<'TEST'
start=$SECONDS
docker compose --env-file /dev/null config -q
docker compose --env-file /dev/null up -d
version=$(docker compose exec -T dify-ssrf-proxy squid -v)
grep -q '^Squid Cache: Version 7\.7$' <<<"$version"
docker compose exec -T dify-ssrf-proxy sh -ec '
  test "$(id -u)" = 10001
  awk "/^Uid:/ { if (\$2 == 0 || \$3 == 0 || \$4 == 0 || \$5 == 0) exit 1; found=1 } END { if (!found) exit 1 }" /proc/1/status
'
docker compose exec -T dify-ssrf-proxy squid -k parse
for _ in $(seq 1 30); do
  if docker compose exec -T dify-api curl -fsS --max-time 2 --noproxy '' \
      --proxy http://dify-ssrf-proxy:3128 http://example.com/ >/dev/null; then
    break
  fi
  sleep 1
done
echo 'Idle Squid memory (kB):'
docker compose exec -T dify-ssrf-proxy sh -c 'grep -E "^Vm(RSS|HWM):" /proc/1/status'
# Same command/assertions as the full-stack CI and operator path, including restart.
bash "$SQUID_TEST_ROOT/scripts/test-ssrf-proxy.sh"
echo 'Squid memory after ACL suite and restart (kB):'
docker compose exec -T dify-ssrf-proxy sh -c 'grep -E "^Vm(RSS|HWM):" /proc/1/status'
# Concurrent allowed requests exercise the 128m container without changing ACLs.
docker compose exec -T dify-api sh -ec '
  pids=""
  for i in $(seq 1 16); do
    curl -fsS --max-time 10 --noproxy "" --proxy http://dify-ssrf-proxy:3128 \
      https://example.com/ >/dev/null &
    pids="$pids $!"
  done
  for pid in $pids; do wait "$pid"; done
'
echo 'Squid memory after concurrent requests (kB):'
docker compose exec -T dify-ssrf-proxy sh -c 'grep -E "^Vm(RSS|HWM):" /proc/1/status'
# Uncapped descriptor tables idle at ~125MiB against the 128MiB limit: require
# the peak to stay under half of it.
docker compose exec -T dify-ssrf-proxy awk '/^VmHWM:/ { exit !($2 < 65536) }' /proc/1/status
echo "PASS: Squid 7.7 contract in $((SECONDS - start))s"
TEST
# 155s + 2s kill grace + 17s cleanup <180s, excluding both image builds.
timeout --signal=TERM --kill-after=2s 155s bash -euo pipefail "$work/test.sh" </dev/null
