#!/bin/bash

# Remove existing .env to force regeneration
rm -f .env

cp .env.example .env

# Replace placeholders with random values using a loop to ensure all occurrences are replaced with the same value per type
S16=$(openssl rand -hex 16)
S32=$(openssl rand -hex 32)
S64=$(openssl rand -hex 64)

# Create a robust password that passes Chatwoot v4.x validation:
# - Needs Uppercase, Lowercase, Number, and Special Character.
ROBUST_PASSWORD="NexaDuo@2026-$(openssl rand -hex 4 | tr '[:lower:]' '[:upper:]')"

# Use | as delimiter to avoid issues with / if any
sed -i "s|\${secret_hex_16}|${S16}|g" .env
sed -i "s|\${secret_hex_32}|${S32}|g" .env
sed -i "s|\${secret_hex_64}|${S64}|g" .env

# Overwrite ADMIN_PASSWORD with the robust one
sed -i "s|^ADMIN_PASSWORD=.*|ADMIN_PASSWORD=${ROBUST_PASSWORD}|" .env

echo ".env generated with random secrets and a robust admin password."
