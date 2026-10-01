#!/usr/bin/env bash
# Checksum gating with fake Docker/Compose only: no daemon or production state.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
REPO_ROOT="$tmp"
mkdir -p "$tmp/observability/prometheus"
printf 'synthetic config\n' > "$tmp/observability/prometheus/prometheus.yml"
restarts=0
fail_restart=0
fail_config=0
fail_ready=0
running=1
sleep() { :; }
dc() {
  case "$*" in
    'ps -q --status running prometheus') [[ $running == 0 ]] || echo synthetic-container ;;
    'restart --no-deps prometheus')
      restarts=$((restarts + 1))
      [[ "$fail_restart" == 0 ]] ;;
    *) echo "Unexpected compose call: $*" >&2; return 1 ;;
  esac
}
docker() {
  case "$*" in
    'exec synthetic-container promtool check config /etc/prometheus/prometheus.yml') [[ $fail_config == 0 ]] ;;
    'exec synthetic-container wget '*) [[ $fail_ready == 0 ]] ;;
    'exec synthetic-container cat /prometheus/config.sha256') cat "$tmp/marker" ;;
    'exec -i synthetic-container sh -c '*) cat > "$tmp/marker" ;;
    *) echo "Unexpected docker call: $*" >&2; return 1 ;;
  esac
}
source "$ROOT/scripts/lib/prometheus-config.sh"
reload_prometheus_config
[[ "$restarts" == 1 && -s "$tmp/marker" ]]
reload_prometheus_config
[[ "$restarts" == 1 ]]
echo changed >> "$tmp/observability/prometheus/prometheus.yml"
fail_restart=1
if reload_prometheus_config; then echo 'FAIL: restart failure ignored'; exit 1; fi
[[ "$restarts" == 2 ]]
fail_restart=0
reload_prometheus_config
[[ "$restarts" == 3 ]]
reload_prometheus_config
[[ "$restarts" == 3 ]]
echo 'PASS: checksum reload, no-op stability, failure leaves marker stale and retries'

echo invalid >> "$tmp/observability/prometheus/prometheus.yml"
fail_config=1
if reload_prometheus_config; then exit 1; fi
[[ "$restarts" == 3 ]]
fail_config=0
fail_ready=1
if reload_prometheus_config; then exit 1; fi
[[ "$restarts" == 4 ]]
fail_ready=0
reload_prometheus_config
[[ "$restarts" == 5 ]]
echo 'groups: []' > "$tmp/observability/prometheus/rules.yml"
reload_prometheus_config
[[ "$restarts" == 6 ]]
running=0
if reload_prometheus_config; then exit 1; fi
echo 'PASS: invalid config, readiness failure, rule edit and absent service'
