#!/usr/bin/env bash
set -euo pipefail

# Navigate to project root
cd "$(dirname "$0")/.."

if [[ -f .env ]] && [[ "${1:-}" != "-f" ]]; then
  echo ".env already exists. Use -f to force overwrite."
  exit 0
fi

echo "Generating .env from .env.example..."
cp .env.example .env

# Generate secrets
S16=$(openssl rand -hex 16)
S32=$(openssl rand -hex 32)
S64=$(openssl rand -hex 64)
# Chatwoot v4.x requires: Uppercase, Lowercase, Number, and Special Character.
ROBUST_PASSWORD="NexaDuo@2026-$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')"

# Replace placeholders
sed -i "s|\${secret_hex_16}|${S16}|g" .env
sed -i "s|\${secret_hex_32}|${S32}|g" .env
sed -i "s|\${secret_hex_64}|${S64}|g" .env

# Force robust password for Admin
sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ROBUST_PASSWORD}|" .env

echo ".env generated successfully."
