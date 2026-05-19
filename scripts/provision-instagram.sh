#!/usr/bin/env bash
# scripts/provision-instagram.sh

set -euo pipefail

INSTANCE_NAME="${1:-}"
CHATWOOT_ACCOUNT_ID="${2:-}"

if [ -z "$INSTANCE_NAME" ] || [ -z "$CHATWOOT_ACCOUNT_ID" ]; then
  echo "Usage: $0 <instance_name> <chatwoot_account_id>"
  exit 1
fi

# Load .env
ENV_FILE="$(dirname "$0")/../.env"
if [ ! -f "$ENV_FILE" ]; then
  echo "Error: .env file not found at $ENV_FILE"
  exit 1
fi

# Function to extract env var
get_env_var() {
  local var_name=$1
  grep "^${var_name}=" "$ENV_FILE" | cut -d '=' -f2- | sed 's/^["'\'']//;s/["'\'']$//' || echo ""
}

API_KEY=$(get_env_var "EVOLUTION_AUTHENTICATION_API_KEY")
EVOLUTION_CHATWOOT_URL=$(get_env_var "EVOLUTION_CHATWOOT_URL")
CHATWOOT_API_TOKEN=$(get_env_var "CHATWOOT_API_TOKEN")

if [ -z "$API_KEY" ]; then
  echo "Error: EVOLUTION_AUTHENTICATION_API_KEY not found in .env"
  exit 1
fi

if [ -z "$EVOLUTION_CHATWOOT_URL" ]; then
  echo "Error: EVOLUTION_CHATWOOT_URL not found in .env"
  exit 1
fi

if [ -z "$CHATWOOT_API_TOKEN" ]; then
  echo "Error: CHATWOOT_API_TOKEN not found in .env"
  exit 1
fi

EVO_URL="http://localhost:8080"

echo "=== Provisioning Instagram Instance: $INSTANCE_NAME ==="

# 1. Create Instance
echo "Creating instance $INSTANCE_NAME..."
CREATE_RESPONSE=$(curl --silent --location --request POST "$EVO_URL/instance/create" \
--header "apikey: $API_KEY" \
--header 'Content-Type: application/json' \
--data "{
    \"instanceName\": \"$INSTANCE_NAME\",
    \"token\": \"\",
    \"integration\": \"instagram\",
    \"qrcode\": false
}")

if echo "$CREATE_RESPONSE" | grep -q "\"status\":\"SUCCESS\"" || echo "$CREATE_RESPONSE" | grep -q "\"instance\":"; then
  echo "Instance creation initiated successfully."
else
  echo "Error creating instance: $CREATE_RESPONSE"
  exit 1
fi

echo -e "\nConfiguring Chatwoot integration for $INSTANCE_NAME..."
# 2. Configure Chatwoot Integration
SET_RESPONSE=$(curl --silent --location --request POST "$EVO_URL/chatwoot/set/$INSTANCE_NAME" \
--header "apikey: $API_KEY" \
--header 'Content-Type: application/json' \
--data "{
    \"enabled\": true,
    \"accountId\": \"$CHATWOOT_ACCOUNT_ID\",
    \"url\": \"$EVOLUTION_CHATWOOT_URL\",
    \"token\": \"$CHATWOOT_API_TOKEN\",
    \"importMessages\": true,
    \"syncContact\": true
}")

if echo "$SET_RESPONSE" | grep -q "\"status\":\"SUCCESS\"" || echo "$SET_RESPONSE" | grep -q "\"enabled\":true"; then
  echo "Chatwoot integration configured successfully."
else
  echo "Error configuring Chatwoot: $SET_RESPONSE"
  exit 1
fi

echo "Provisioning complete for $INSTANCE_NAME."
