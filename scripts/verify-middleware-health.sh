#!/usr/bin/env bash
# =============================================================================
# verify-middleware-health.sh — focused probe for the Middleware bridge
# (DEPLOY-03). Checks /health (public) and /config (Bearer auth required).
#
# Reads HANDOFF_SHARED_SECRET from .env if present, else expects it in env.
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Load HANDOFF_SHARED_SECRET from .env if available (mirrors backup.sh pattern)
if [[ -f "${REPO_ROOT}/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "${REPO_ROOT}/.env"
  set +a
fi
: "${HANDOFF_SHARED_SECRET:?HANDOFF_SHARED_SECRET not set (export it or add to .env)}"

MIDDLEWARE_URL="${MIDDLEWARE_URL:-http://localhost:4000}"

step "Probing ${MIDDLEWARE_URL}/health (no auth)"
code=$(curl -s -o /dev/null -w '%{http_code}' "${MIDDLEWARE_URL}/health" || true)
[[ "$code" == "200" ]] || fail "Middleware /health returned ${code} (expected 200)"

step "Probing ${MIDDLEWARE_URL}/config (Bearer auth)"
code=$(curl -s -o /dev/null -w '%{http_code}' \
  -H "Authorization: Bearer ${HANDOFF_SHARED_SECRET}" \
  "${MIDDLEWARE_URL}/config" || true)
[[ "$code" == "200" ]] || fail "Middleware /config returned ${code} (expected 200)"

echo "OK middleware healthy at ${MIDDLEWARE_URL}"
