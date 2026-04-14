#!/usr/bin/env bash
set -euo pipefail

echo "==> Auditing Phase 2: Management & Edge Connectivity"

# 1. DNS Subdomain Check
echo "--- Checking DNS strategy ---"
BASE_DOMAIN=$(grep 'default = "chat.nexaduo.com"' infrastructure/terraform/envs/production/variables.tf || echo "NotFound")
DIFY_RECORD=$(grep 'name    = "dify.chat"' infrastructure/terraform/envs/production/main.tf || echo "NotFound")

if [[ "$BASE_DOMAIN" == *"chat.nexaduo.com"* && "$DIFY_RECORD" == *"dify.chat"* ]]; then
  echo "[FAIL] DNS strategy matches old wildcard/sub-subdomain (chat.nexaduo.com, dify.chat.nexaduo.com)"
  echo "Expected: Unified subdomains (chat.nexaduo.com, dify.nexaduo.com)"
else
  echo "[PASS] DNS strategy appears to be unified (or at least not the old one)"
fi

# 2. Firewall Check
echo "--- Checking Firewall rules ---"
PUBLIC_INGRESS=$(grep -A 10 "google_compute_firewall\" \"allow_http_https\"" infrastructure/terraform/modules/gcp-vm/main.tf | grep "source_ranges = \[\"0.0.0.0/0\"\]" || echo "NotFound")

if [[ "$PUBLIC_INGRESS" != "NotFound" ]]; then
  echo "[FAIL] GCP Firewall allows public ingress (0.0.0.0/0). This violates ROUTE-04."
else
  echo "[PASS] GCP Firewall is hardened."
fi

# 3. Cloudflare Tunnel configuration
echo "--- Checking Cloudflare Tunnel config ---"
TUNNEL_CONFIG="infrastructure/terraform/modules/cloudflare-tunnel/main.tf"
if grep -q "hostname = \"coolify.\${var.base_domain}\"" "$TUNNEL_CONFIG" && \
   grep -q "hostname = var.base_domain" "$TUNNEL_CONFIG" && \
   grep -q "hostname = \"dify.\${var.base_domain}\"" "$TUNNEL_CONFIG"; then
  echo "[INFO] Cloudflare Tunnel ingress rules found."
  # If base_domain is chat.nexaduo.com, this results in dify.chat.nexaduo.com
  if [[ "$BASE_DOMAIN" == *"chat.nexaduo.com"* ]]; then
    echo "[FAIL] Tunnel hostnames will be sub-subdomains (e.g., dify.chat.nexaduo.com) instead of unified."
  fi
else
  echo "[FAIL] Cloudflare Tunnel ingress rules are missing or incomplete."
fi

# 4. Backup Rotation Check
echo "--- Checking Backup rotation ---"
BACKUP_SCRIPT="scripts/backup.sh"
if [[ -f "$BACKUP_SCRIPT" ]]; then
  if grep -q "BACKUP_KEEP_DAYS:=" "$BACKUP_SCRIPT" && grep -q "find.*-delete" "$BACKUP_SCRIPT"; then
    echo "[PASS] Local backup rotation is implemented in $BACKUP_SCRIPT."
  else
    echo "[FAIL] Backup rotation logic not found in $BACKUP_SCRIPT."
  fi
else
  echo "[FAIL] Backup script $BACKUP_SCRIPT not found."
fi

echo "==> Audit complete."
