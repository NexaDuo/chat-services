#!/usr/bin/env bash
# =============================================================================
# verify-observability.sh — focused probe for the observability stack
# (DEPLOY-04). Checks Grafana, Prometheus, and Loki reachability.
# =============================================================================
set -euo pipefail

step() { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

GRAFANA_URL="${GRAFANA_URL:-http://localhost:3002}"
PROMETHEUS_URL="${PROMETHEUS_URL:-http://localhost:9090}"
LOKI_URL="${LOKI_URL:-http://localhost:3100}"

step "Probing Grafana ${GRAFANA_URL}/login"
code=$(curl -s -o /dev/null -w '%{http_code}' "${GRAFANA_URL}/login" || true)
[[ "$code" == "200" ]] || fail "Grafana returned ${code} (expected 200)"

step "Probing Prometheus ${PROMETHEUS_URL}/-/healthy"
code=$(curl -s -o /dev/null -w '%{http_code}' "${PROMETHEUS_URL}/-/healthy" || true)
[[ "$code" == "200" ]] || fail "Prometheus returned ${code} (expected 200)"

step "Probing Loki ${LOKI_URL}/ready"
code=$(curl -s -o /dev/null -w '%{http_code}' "${LOKI_URL}/ready" || true)
[[ "$code" == "200" ]] || fail "Loki returned ${code} (expected 200)"

# Confirm Prometheus has at least one healthy 'up' target (proves scraping works)
step "Confirming Prometheus has at least one UP target"
up_count=$(curl -s "${PROMETHEUS_URL}/api/v1/query?query=up" \
  | grep -o '"value":\["[0-9.]*","1"\]' | wc -l || echo 0)
[[ "$up_count" -ge 1 ]] || fail "Prometheus has 0 UP targets — scraping not functional"

echo "OK observability healthy: grafana, prometheus (${up_count} UP targets), loki"
