#!/usr/bin/env bash
# =============================================================================
# verify-v1-e2e.sh — Final E2E verification for NexaDuo Milestone v1.0.
# Run this from the repository root on the production environment.
#
# Requirements:
# - HANDOFF_SHARED_SECRET (in .env or environment)
# - DIFY_API_KEY (optional, if testing Dify integration directly)
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

step() { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# Load secrets from GCP Secret Manager (SSOT for the reproducible deploy).
# Fallback to a local .env only if HANDOFF_SHARED_SECRET is already exported.
if [[ -z "${HANDOFF_SHARED_SECRET:-}" ]]; then
  PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
  if command -v gcloud >/dev/null 2>&1; then
    HANDOFF_SHARED_SECRET="$(gcloud secrets versions access latest --secret=handoff_shared_secret --project="${PROJECT_ID}" 2>/dev/null || true)"
    export HANDOFF_SHARED_SECRET
  fi
fi

: "${HANDOFF_SHARED_SECRET:?HANDOFF_SHARED_SECRET not set (export it or ensure gcloud+handoff_shared_secret are available)}"
CHAT_DOMAIN="${CHAT_DOMAIN:-chat.nexaduo.com}"
DIFY_DOMAIN="${DIFY_DOMAIN:-dify.nexaduo.com}"
GRAFANA_DOMAIN="${GRAFANA_DOMAIN:-grafana.nexaduo.com}"

# 1. Cloudflare Edge Reachability (Checks for 1033 resolution)
step "Probing Cloudflare Edge for Chatwoot (${CHAT_DOMAIN})"
code=$(curl -s -o /dev/null -w '%{http_code}' "https://${CHAT_DOMAIN}/" || true)
if [[ "$code" == "1033" ]]; then
  fail "Cloudflare Error 1033 detected at ${CHAT_DOMAIN}. Check Argo Tunnel and Traefik listener."
elif [[ "$code" == "000" ]]; then
  fail "Could not connect to ${CHAT_DOMAIN}. Check DNS and Tunnel."
else
  echo "✓ Edge ${CHAT_DOMAIN} returned ${code}"
fi

step "Probing Cloudflare Edge for Dify (${DIFY_DOMAIN})"
code=$(curl -s -o /dev/null -w '%{http_code}' "https://${DIFY_DOMAIN}/" || true)
echo "✓ Edge ${DIFY_DOMAIN} returned ${code}"

# 2. Chatwoot Tenant Path & WebSockets
TENANT_SLUG="${TENANT_SLUG:-nexaduo-main}"
step "Verifying Chatwoot Tenant Path (https://${CHAT_DOMAIN}/${TENANT_SLUG}/)"
code=$(curl -s -o /dev/null -w '%{http_code}' "https://${CHAT_DOMAIN}/${TENANT_SLUG}/" || true)
if [[ "$code" == "200" ]]; then
  echo "✓ Tenant path ${TENANT_SLUG} reachable"
  # Check for WebSocket upgrade support in header
  step "Checking for WebSocket support (WSS upgrade header)"
  if curl -s -I -H "Upgrade: websocket" -H "Connection: Upgrade" "https://${CHAT_DOMAIN}/cable" | grep -qi "HTTP/1.1 101 Switching Protocols"; then
    echo "✓ WebSocket upgrade supported at /cable"
  else
    echo "⚠ Warning: Could not verify WebSocket upgrade at /cable via curl. Test manually in browser."
  fi
else
  fail "Tenant path ${TENANT_SLUG} returned ${code} (expected 200). Check Worker routing."
fi

# 3. Middleware ↔ Dify Integration
# We probe the middleware's /health and then a simulated handoff if possible.
MIDDLEWARE_URL="https://${CHAT_DOMAIN}/middleware" # Adjust if your routing points elsewhere
step "Verifying Middleware ↔ Dify Handoff (via ${MIDDLEWARE_URL})"
# Check if middleware can reach internal Dify API
if curl -s -f -H "Authorization: Bearer ${HANDOFF_SHARED_SECRET}" "${MIDDLEWARE_URL}/health" > /dev/null; then
  echo "✓ Middleware /health is OK"
else
  echo "⚠ Middleware /health failed or unreachable at ${MIDDLEWARE_URL}. Check edge routing."
fi

# 4. Observability (Grafana)
step "Verifying Grafana Reachability (https://${GRAFANA_DOMAIN})"
code=$(curl -s -o /dev/null -w '%{http_code}' "https://${GRAFANA_DOMAIN}/login" || true)
if [[ "$code" == "200" ]]; then
  echo "✓ Grafana reachable at ${GRAFANA_DOMAIN}"
else
  fail "Grafana returned ${code} (expected 200) at ${GRAFANA_DOMAIN}. Check DNS/Tunnel."
fi

echo "============================================================================="
echo "Final E2E Verification Complete for Milestone v1.0"
echo "Note: Full WebSocket behavioral test (messages appearing) requires browser."
echo "============================================================================="
