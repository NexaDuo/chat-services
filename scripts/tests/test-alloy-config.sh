#!/usr/bin/env bash
# Checksum gating with fake Docker/Compose only: no daemon or production state.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
REPO_ROOT="$tmp"
mkdir -p "$tmp/observability/alloy"
printf 'synthetic config\n' > "$tmp/observability/alloy/config.alloy"
restarts=0
fail_restart=0
dc() {
  case "$*" in
    'ps -q --status running alloy') echo synthetic-container ;;
    'restart --no-deps alloy')
      restarts=$((restarts + 1))
      [[ "$fail_restart" == 0 ]] ;;
    *) echo "Unexpected compose call: $*" >&2; return 1 ;;
  esac
}
docker() {
  case "$*" in
    'exec synthetic-container cat /var/lib/alloy/config.sha256') cat "$tmp/marker" ;;
    'exec -i synthetic-container sh -c '*) cat > "$tmp/marker" ;;
    *) echo "Unexpected docker call: $*" >&2; return 1 ;;
  esac
}
source "$ROOT/scripts/lib/alloy-config.sh"
reload_alloy_config
[[ "$restarts" == 1 && -s "$tmp/marker" ]]
reload_alloy_config
[[ "$restarts" == 1 ]]
echo changed >> "$tmp/observability/alloy/config.alloy"
fail_restart=1
if reload_alloy_config; then echo 'FAIL: restart failure ignored'; exit 1; fi
[[ "$restarts" == 2 ]]
fail_restart=0
reload_alloy_config
[[ "$restarts" == 3 ]]
reload_alloy_config
[[ "$restarts" == 3 ]]
echo 'PASS: checksum reload, no-op stability, failure leaves marker stale and retries'
