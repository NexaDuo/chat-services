#!/usr/bin/env bash
# CI-only real-producer contract (#250); never point this at the host stack.
set -euo pipefail
[[ "${CI:-}" == true && "${COMPOSE_PROJECT_NAME:-}" == nexaduo ]] || {
  echo 'Refusing: requires CI=true and COMPOSE_PROJECT_NAME=nexaduo' >&2
  exit 1
}
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cleanup() {
  docker compose exec -T middleware sh -c '
    if [ -f /tmp/agent-bot-contract.pid ]; then kill "$(cat /tmp/agent-bot-contract.pid)" 2>/dev/null || true; fi
    rm -f /tmp/agent-bot-contract.pid /tmp/agent-bot-receiver.cjs
  ' >/dev/null 2>&1 || true
}
trap cleanup EXIT
# No host listener/port, and no new image: run the tap in the CI middleware.
docker compose cp "$ROOT/scripts/tests/agent-bot-receiver.cjs" middleware:/tmp/agent-bot-receiver.cjs
docker compose exec -T -d middleware node /tmp/agent-bot-receiver.cjs
ready=0
for _ in {1..20}; do
  if docker compose exec -T middleware node -e 'fetch("http://127.0.0.1:4100/events").then(r => process.exit(r.ok ? 0 : 1)).catch(() => process.exit(1))'; then
    ready=1
    break
  fi
  sleep 1
done
[[ "$ready" == 1 ]] || { echo 'FAIL: contract receiver not ready' >&2; exit 1; }
timeout 120 docker compose exec -T chatwoot-rails bundle exec rails runner - < "$ROOT/scripts/tests/agent-bot-contract.rb"
