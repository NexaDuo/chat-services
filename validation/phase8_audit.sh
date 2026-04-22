#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

pass_count=0
fail_count=0

check_contains() {
  local file="$1"
  local pattern="$2"
  local label="$3"
  if grep -qE "$pattern" "$file"; then
    echo "[PASS] $label"
    pass_count=$((pass_count + 1))
  else
    echo "[FAIL] $label"
    fail_count=$((fail_count + 1))
  fi
}

echo "==> Auditing Phase 8: Production Provisioning & Rollout"

check_contains "scripts/health-check-all.sh" "coolify\\.service\\.subName|docker ps" \
  "Health check script contains runtime container discovery"

check_contains "scripts/refresh-coolify-routes.sh" "check_public_not_404|coolify-proxy" \
  "Route refresh script enforces non-404 checks and proxy reload flow"

check_contains "edge/cloudflare-worker/src/index.ts" "Authorization.*Bearer.*SHARED_SECRET|SHARED_SECRET" \
  "Cloudflare worker forwards authenticated tenant resolution requests"

check_contains "middleware/src/handlers/chatwoot-webhook.ts" "x-chatwoot-webhook-token|unauthorized" \
  "Middleware enforces Chatwoot webhook token validation"

if grep -q '"name": "NexaDuo Main"' provisioning/tenants.json; then
  echo "[PASS] Tenant registry contains NexaDuo Main"
  pass_count=$((pass_count + 1))
else
  echo "[FAIL] Tenant registry missing NexaDuo Main"
  fail_count=$((fail_count + 1))
fi

echo
echo "Checks: $pass_count passed, $fail_count failed"

if [[ $fail_count -gt 0 ]]; then
  echo "==> Audit complete. Status: FAIL"
  exit 1
fi

echo "==> Audit complete. Status: PASS"
