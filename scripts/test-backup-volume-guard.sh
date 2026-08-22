#!/usr/bin/env bash
# =============================================================================
# test-backup-volume-guard.sh — deterministic regression test for the
# section-6b volume-size guard in backup-host.sh.
#
# Root cause covered: the guard treated ANY volume archive under
# BACKUP_VOLUME_MIN_BYTES as suspicious, with no exception for a volume that
# is legitimately empty by design (evolution-instances — this Evolution API
# v2 deployment persists all instance/session state in Postgres via
# DATABASE_ENABLED, not on disk). That false positive made backup-host.sh
# exit 1 on an otherwise-successful backup, which meant the `.last-success`
# marker (section 7) was never written, which meant health-check-all.sh's
# backup-staleness check (section 6) failed FOREVER — the silent-backup-
# failure detector was itself silently broken.
#
# This is on-demand CLI logic (not observable in any web flow — AGENTS.md
# explicitly exempts this class from the mandatory Playwright regression
# rule), so the regression test here is a deterministic shell unit test
# instead: it sources backup-host.sh in BACKUP_HOST_TEST_MODE=1 (which
# short-circuits before any Docker/Postgres access) to reuse the exact same
# backup_volume_size_guard_should_fail() function and
# BACKUP_EMPTY_OK_VOLUME_SUFFIXES allowlist the real script runs — not a
# reimplementation that could silently drift from it — and exercises three
# cases:
#   1. empty + allowlisted        (evolution-instances, 87 bytes) -> must NOT fail
#   2. empty + NOT allowlisted    (grafana-data,        87 bytes) -> MUST fail
#   3. normal size                (chatwoot-storage,  355708 bytes) -> must NOT fail
#
# Run: bash scripts/test-backup-volume-guard.sh
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

export BACKUP_HOST_TEST_MODE=1
# shellcheck source=backup-host.sh
source "${SCRIPT_DIR}/backup-host.sh"

MIN_BYTES=100
fail_count=0

assert_case() {
  local desc="$1" suffix="$2" size="$3" expect_fail="$4"
  local got_fail=0
  backup_volume_size_guard_should_fail "$suffix" "$size" "$MIN_BYTES" && got_fail=1 || got_fail=0
  if [[ "$got_fail" == "$expect_fail" ]]; then
    echo "PASS: ${desc} (suffix=${suffix} size=${size} expect_fail=${expect_fail})"
  else
    echo "FAIL: ${desc} (suffix=${suffix} size=${size}) — expected should_fail=${expect_fail}, got ${got_fail}"
    fail_count=$((fail_count + 1))
  fi
}

# Case 1: empty volume that IS on the empty-by-design allowlist -> guard must NOT fail.
assert_case "allowlisted empty volume is exempt" "evolution-instances" 87 0

# Case 2: empty volume that is NOT on the allowlist -> guard MUST still fail
# (proves the exception is narrow and didn't weaken the guard globally).
assert_case "non-allowlisted empty volume still fails" "grafana-data" 87 1

# Case 3: normal-sized archive, allowlisted or not -> guard must NOT fail
# (proves the allowlist doesn't mask a real regression once the volume is
# non-empty, e.g. if Evolution starts writing to disk again).
assert_case "normal-sized archive never fails regardless of allowlist" "chatwoot-storage" 355708 0
assert_case "normal-sized allowlisted volume also passes on its own merit" "evolution-instances" 355708 0

if [[ "$fail_count" -eq 0 ]]; then
  echo "OK: all backup_volume_size_guard_should_fail() cases passed"
  exit 0
else
  echo "FAILED: ${fail_count} case(s) did not match expected behavior"
  exit 1
fi
