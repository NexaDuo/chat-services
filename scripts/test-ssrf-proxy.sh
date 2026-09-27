#!/usr/bin/env bash
# Issue #222: exercise the real Squid from dify-api on the stack network.
# Uses the caller's COMPOSE_FILE/--env-file defaults; no secrets or host ports.
set -euo pipefail

proxy=http://dify-ssrf-proxy:3128
probe() {
  local expected=$1 url=$2 response status
  shift 2
  # Empty noproxy prevents inherited bypasses. Never follow redirects: each
  # public request must produce a real success, not an untested Location.
  response=$(docker compose exec -T dify-api curl --silent --show-error \
    --connect-timeout 5 --max-time 25 --noproxy '' --proxy "$proxy" \
    --include --write-out '\n%{http_code}' "$@" "$url")
  status=${response##*$'\n'}
  if [[ "$status" != "$expected" ]]; then
    echo "FAIL: $url expected $expected, got $status" >&2
    return 1
  fi
  if [[ "$expected" == 403 ]] && ! [[ "$response" =~ [Xx]-[Ss]quid-[Ee]rror:\ ERR_ACCESS_DENIED ]]; then
    echo "FAIL: $url did not return Squid ERR_ACCESS_DENIED" >&2
    return 1
  fi
  if [[ "$expected" == 401 && "$response" != *'"error":"unauthorized"'* ]]; then
    echo "FAIL: handoff did not reach middleware authentication" >&2
    return 1
  fi
  echo "PASS: $url -> $expected"
}

# Assert wiring as well as proxy behavior: forced curl alone would not detect
# a service silently losing its proxy environment during a compose merge.
for service in dify-api dify-worker dify-plugin-daemon; do
  docker compose exec -T "$service" sh -c '
    test "$SSRF_PROXY_HTTP_URL" = http://dify-ssrf-proxy:3128 &&
    test "$SSRF_PROXY_HTTPS_URL" = http://dify-ssrf-proxy:3128
  '
done
docker compose exec -T dify-sandbox sh -c '
  test "$HTTP_PROXY" = http://dify-ssrf-proxy:3128 &&
  test "$HTTPS_PROXY" = http://dify-ssrf-proxy:3128 &&
  test -z "$NO_PROXY" && test -z "$no_proxy"
'

# Parse the mounted config with the exact pinned image before exercising it.
docker compose exec -T dify-ssrf-proxy squid -k parse
for url in \
  http://169.254.169.254/ http://postgres:5432/ http://postgres/ \
  http://127.0.0.1/ http://10.0.0.1/ http://172.16.0.1/ \
  http://192.168.0.1/ http://100.64.0.1/ http://0.0.0.1/ \
  'http://[::1]/' 'http://[fe80::1]/' 'http://[fc00::1]/' \
  'http://[::ffff:127.0.0.1]/' 'http://[64:ff9b::7f00:1]/' \
  http://example.com:8080/ http://middleware:4000/health \
  http://middleware/tools/handoff; do
  probe 403 "$url"
done
probe 403 http://postgres:4000/tools/handoff --request POST
probe 403 http://127.0.0.1:4000/tools/handoff --request POST
probe 403 http://middleware:4000/tools/handoff
probe 403 http://middleware:4000/tools/handoff/ --request POST
probe 401 http://middleware:4000/tools/handoff --request POST
probe 200 http://example.com/
# HTTPS proves CONNECT 443 works; explicit CONNECT 80 must be rejected.
probe 200 https://example.com/
probe 403 http://example.com:80/ --request CONNECT --request-target example.com:80
