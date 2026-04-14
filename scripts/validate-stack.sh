#!/usr/bin/env bash
# validate-stack.sh — full-cycle validation: fresh stack + automation.
# Exits 0 on success. On failure, prints the offending step + a log tail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEPLOY_DIR="$REPO_ROOT/deploy"
AUTOMATION_DIR="$REPO_ROOT/automation"
LOG_DIR="$(mktemp -d)"
trap 'echo "Logs retained at: $LOG_DIR"' EXIT

step() { echo "==> $*"; }
fail() {
  echo "FAIL: $1" >&2
  if [[ -n "${2:-}" && -f "$2" ]]; then
    echo "---- last 60 lines of $2 ----" >&2
    tail -60 "$2" >&2
  fi
  exit 1
}

# 1. Clean slate
step "docker compose down -v"
(cd "$DEPLOY_DIR" && docker compose down -v) >"$LOG_DIR/down.log" 2>&1 \
  || fail "compose down failed" "$LOG_DIR/down.log"

# 2. Bring up
step "docker compose up -d"
(cd "$DEPLOY_DIR" && docker compose up -d) >"$LOG_DIR/up.log" 2>&1 \
  || fail "compose up failed" "$LOG_DIR/up.log"

# 3. Wait for healthchecks (postgres, redis, chatwoot-rails)
step "waiting for chatwoot-rails to be healthy (up to 5 min)"
for i in $(seq 1 60); do
  status=$(docker inspect -f '{{.State.Health.Status}}' nexaduo-chatwoot-rails 2>/dev/null || echo "missing")
  [[ "$status" == "healthy" ]] && break
  sleep 5
done
[[ "$status" == "healthy" ]] || fail "chatwoot-rails never became healthy (status=$status)"

# 4. Wait for Dify API
step "waiting for Dify API (up to 3 min)"
for i in $(seq 1 36); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:5001/console/api/setup || true)
  [[ "$code" == "200" ]] && break
  sleep 5
done
[[ "$code" == "200" ]] || fail "Dify API never returned 200 (last=$code)"

# 5. Run Playwright automation
step "running Playwright automation"
(cd "$AUTOMATION_DIR" && node initial-setup.js) >"$LOG_DIR/automation.log" 2>&1 \
  || fail "automation script errored" "$LOG_DIR/automation.log"

# 6. Assert both automations reported success (idempotent = also success)
grep -Eq "OK Chatwoot Admin created successfully|Chatwoot is already configured" "$LOG_DIR/automation.log" \
  || fail "Chatwoot automation did not succeed" "$LOG_DIR/automation.log"
grep -Eq "OK Dify Admin created successfully|Dify is already configured" "$LOG_DIR/automation.log" \
  || fail "Dify automation did not succeed" "$LOG_DIR/automation.log"

# 7. Sanity: no container should be in restart loop
bad=$(docker ps --filter "name=nexaduo-" --format '{{.Names}} {{.Status}}' | grep -Ei 'restart|unhealthy' || true)
[[ -z "$bad" ]] || { echo "$bad" >&2; fail "unhealthy/restarting containers detected"; }

echo "OK stack validated — all services healthy, automation idempotent"
trap - EXIT
rm -rf "$LOG_DIR"
