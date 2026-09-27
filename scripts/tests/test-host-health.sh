#!/usr/bin/env bash
# Real script entrypoints; PATH stubs prevent any access to the host daemon.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"
mkdir -p "$HOME" "$TMP/bin" "$TMP/dumps"
export PATH="$TMP/bin:$PATH" BACKUP_DIR="$TMP/dumps" DUMPS_DIR="$TMP/dumps"
export ENV_FILE="$TMP/test.env"
unset ALLOW_NON_DESKTOP_ENGINE SKIP_BACKUP_CHECK
echo 'CHATWOOT_FRONTEND_URL=https://chat.example.test' > "$ENV_FILE"
cat > "$TMP/bin/docker" <<'STUB'
#!/bin/bash
case "$*" in
  "info --format {{.OperatingSystem}}")
    [[ "${MOCK_OS:-}" != unavailable ]] || exit 127
    echo "$MOCK_OS" ;;
  "compose version"|"network inspect nexaduo-network") exit 0 ;;
  *) echo "Unexpected Docker call: $*" >&2; exit 99 ;;
esac
STUB
cat > "$TMP/bin/crontab" <<'STUB'
#!/bin/bash
case "$1" in
  -l) cat "$HOME/crontab" ;;
  -) cat > "$HOME/crontab.new"; mv "$HOME/crontab.new" "$HOME/crontab" ;;
  *) exit 99 ;;
esac
STUB
cat > "$TMP/bin/pgrep" <<'STUB'
#!/bin/bash
exit 0
STUB
chmod +x "$TMP/bin/"*
for file in fixture.sql.gz fixture-chatwoot-storage-test.tar.gz fixture-dify-api-storage-test.tar.gz env-test.tar.gz; do
  echo synthetic > "$BACKUP_DIR/$file"
done
expect() {
  local expected="$1"; shift
  local status=0
  "$@" > "$TMP/output" 2>&1 || status=$?
  if [[ "$expected" == pass && "$status" != 0 || "$expected" == fail && "$status" == 0 ]]; then
    cat "$TMP/output"; echo "FAIL: $* (status=$status)"; exit 1
  fi
  echo "PASS: $expected: $*"
}
for entry in preflight health; do
  if [[ "$entry" == preflight ]]; then
    cmd=(bash "$ROOT/scripts/run-stack.sh" preflight)
  else
    cmd=(bash "$ROOT/scripts/health-check-all.sh" --host-only)
  fi
  export MOCK_OS='Docker Desktop'
  expect pass "${cmd[@]}"
  export MOCK_OS='Docker Desktop (WSL)'
  expect pass "${cmd[@]}"
  export MOCK_OS='Ubuntu 24.04.3 LTS'
  expect fail "${cmd[@]}"
  grep -q 'systemctl is-enabled docker.socket docker' "$TMP/output"
  expect pass env ALLOW_NON_DESKTOP_ENGINE=1 "${cmd[@]}"
  expect fail env ALLOW_NON_DESKTOP_ENGINE=true "${cmd[@]}"
  export MOCK_OS=unavailable
  expect fail env ALLOW_NON_DESKTOP_ENGINE=1 "${cmd[@]}"
done
export MOCK_OS='Ubuntu 24.04.3 LTS'
expect fail bash "$ROOT/scripts/health-check-all.sh"
grep -q 'Docker engine guard failed' "$TMP/output"
export MOCK_OS='Docker Desktop'
expect pass bash "$ROOT/scripts/scheduled-health-check.sh"
touch -d '27 hours ago' "$BACKUP_DIR/fixture.sql.gz"
expect fail bash "$ROOT/scripts/scheduled-health-check.sh"
test -s "$HOME/nexaduo-local/.health-last-fail"
grep -q 'STALE BACKUP' "$HOME/nexaduo-local/health-check.log"
expect pass bash "$ROOT/scripts/run-stack.sh" preflight
grep -q '!!! PREVIOUS SCHEDULED HOST HEALTH FAILURE' "$TMP/output"
touch "$BACKUP_DIR/fixture.sql.gz"
expect pass bash "$ROOT/scripts/scheduled-health-check.sh"
test ! -f "$HOME/nexaduo-local/.health-last-fail"
export MOCK_OS=unavailable
expect fail bash "$ROOT/scripts/scheduled-health-check.sh"
test -s "$HOME/nexaduo-local/.health-last-fail"
# Contention skips without erasing the prior failure.
(
  flock 9
  expect pass bash "$ROOT/scripts/scheduled-health-check.sh"
  test -s "$HOME/nexaduo-local/.health-last-fail"
) 9>"$HOME/nexaduo-local/.health-check.lock"
echo '0 3 * * * /old/scripts/backup-local.sh' > "$HOME/crontab"
echo '0 0 * * * echo unrelated' >> "$HOME/crontab"
expect pass bash "$ROOT/scripts/run-stack.sh" install-cron
cp "$HOME/crontab" "$TMP/first-cron"
expect pass bash "$ROOT/scripts/run-stack.sh" install-cron
cmp "$TMP/first-cron" "$HOME/crontab"
test "$(grep -c 'scheduled-health-check.sh' "$HOME/crontab")" == 1
test "$(grep -c 'backup-host.sh' "$HOME/crontab")" == 1
grep -q 'echo unrelated' "$HOME/crontab"
# Execute the actual generated hourly command through cron's shell.
export MOCK_OS='Docker Desktop'
line="$(grep 'scheduled-health-check.sh' "$HOME/crontab")"
expect pass /bin/sh -c "${line#15 * * * * }"
# A PATH with no Docker executable must still produce a timestamped marker.
mkdir "$TMP/no-docker"
for tool in bash dirname mkdir date flock timeout cat mv; do
  ln -s "$(command -v "$tool")" "$TMP/no-docker/$tool"
done
expect fail env PATH="$TMP/no-docker" /bin/bash "$ROOT/scripts/scheduled-health-check.sh"
test -s "$HOME/nexaduo-local/.health-last-fail"
grep -q 'cannot query Docker engine' "$HOME/nexaduo-local/health-check.log"
echo 'OK: host health regressions' 
