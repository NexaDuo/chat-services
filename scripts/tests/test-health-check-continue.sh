#!/usr/bin/env bash
# Regression for issue #294: scripts/health-check-all.sh
#  1. aborted on the FIRST failing check, so later sections (backup freshness)
#     never ran, and
#  2. the #157 drift guard failed on a running container whose mem_limit was not
#     declared in MEM_LIMIT_EXPECTED_MIB (chat-services-alloy-1).
# Uses a fake Docker CLI (no host daemon access) like test-host-health.sh.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/dumps"
export PATH="$TMP/bin:$PATH" BACKUP_DIR="$TMP/dumps" MOCK_OS='Docker Desktop'
unset ALLOW_NON_DESKTOP_ENGINE SKIP_BACKUP_CHECK HANDOFF_SHARED_SECRET
export SKIP_ALERT_HEALTH_CHECK=1 COMPOSE_PROJECT_NAME=chat-services
for file in fixture.sql.gz fixture-chatwoot-storage-test.tar.gz fixture-dify-api-storage-test.tar.gz env-test.tar.gz clone-secrets-test.tar.gz.gpg; do
  echo synthetic > "$BACKUP_DIR/$file"
done

# Running containers: alloy (declared limit 768MiB), middleware (256MiB, ok)
# and "ghost" (a limit that is NOT declared in the script = the #294 drift).
cat > "$TMP/bin/sleep" <<'STUB'
#!/bin/bash
exit 0
STUB
cat > "$TMP/bin/docker" <<'STUB'
#!/bin/bash
args="$*"
case "$args" in
  "info --format {{.OperatingSystem}}") echo "$MOCK_OS" ;;
  "compose version"|"network inspect nexaduo-network") exit 0 ;;
  "ps --format {{.Names}}")
    printf '%s\n' chat-services-alloy-1 chat-services-middleware-1 chat-services-ghost-1 ;;
  "ps -a --filter name=^/chat-services-middleware-[0-9]+\$ --format {{.Names}}") echo chat-services-middleware-1 ;;
  ps*) exit 0 ;;
  "inspect -f {{.HostConfig.Memory}} chat-services-alloy-1") echo 805306368 ;;
  "inspect -f {{.HostConfig.Memory}} chat-services-middleware-1") echo 268435456 ;;
  "inspect -f {{.HostConfig.Memory}} chat-services-ghost-1") echo 1073741824 ;;
  "inspect -f {{.HostConfig.LogConfig.Type}}|"*) echo 'json-file|10m|3' ;;
  "inspect -f {{.State.Health.Status}} "*|"inspect -f {{if .State.Health}}"*) echo healthy ;;
  "inspect -f {{.State.Running}} "*) echo true ;;
  exec*) exit 1 ;;
  *) exit 1 ;;  # coolify-proxy etc. are absent
esac
STUB
# SEC-1: never let the script reach a real gcloud (runner / operator machine).
cat > "$TMP/bin/gcloud" <<'STUB'
#!/bin/bash
exit 1
STUB
chmod +x "$TMP/bin/"*

status=0
bash "$ROOT/scripts/health-check-all.sh" > "$TMP/out" 2>&1 || status=$?
fail() { cat "$TMP/out"; echo "FAIL: $1"; exit 1; }

# Overall result is non-zero when anything failed.
[[ "$status" != 0 ]] || fail "expected non-zero exit"
# Drift guard: the undeclared limit is reported, the declared alloy one is not.
grep -q 'chat-services-ghost-1 (subname=ghost).*NOT in MEM_LIMIT_EXPECTED_MIB' "$TMP/out" || fail "undeclared mem_limit not reported"
if grep -q 'FAIL-ITEM: chat-services-alloy-1' "$TMP/out"; then fail "alloy should be declared in MEM_LIMIT_EXPECTED_MIB"; fi
if grep -q 'DRIFT: chat-services-alloy-1' "$TMP/out"; then fail "alloy limit should match declared 768MiB"; fi
# Errexit must stay ON inside the run_check subshell: check_loki aborts at
# require_container (loki absent). If `( set -e; "$@" )` were replaced by a
# `|| rc=$?` form, set -e would be disabled and the step below would print.
if grep -q 'Probing Loki readiness' "$TMP/out"; then fail "errexit lost inside run_check subshell"; fi
# Continue-on-failure: earlier sections failed, yet later ones still ran.
grep -q 'FAILED CHECK: memory-limit coverage' "$TMP/out" || fail "memory section not recorded"
grep -q 'FAILED CHECK: Traefik docker-provider routers' "$TMP/out" || fail "traefik section not recorded"
grep -q 'FAILED CHECK: container healthchecks' "$TMP/out" || fail "healthcheck section not recorded"
grep -q 'backup OK: newest dump fixture.sql.gz' "$TMP/out" || fail "backup freshness section did not run after earlier failures"
grep -q '^SUMMARY: [2-9][0-9]* check(s) FAILED' "$TMP/out" || fail "missing summary"
grep -q '^  - backup freshness' "$TMP/out" && fail "backup freshness should have passed"
# A genuinely stale backup is still caught after the other failures.
touch -d '27 hours ago' "$BACKUP_DIR/fixture.sql.gz"
bash "$ROOT/scripts/health-check-all.sh" > "$TMP/out" 2>&1 && fail "expected non-zero exit"
grep -q 'STALE BACKUP' "$TMP/out" || fail "stale backup not reported"
grep -q '^  - backup freshness' "$TMP/out" || fail "stale backup missing from summary"
echo 'OK: health-check continue-on-failure + undeclared mem_limit drift'
