#!/bin/bash
# scripts/migrate-to-gcp-secrets.sh
# Usage: ./scripts/migrate-to-gcp-secrets.sh [FILE_PATH]

FILE_PATH=${1:-"infrastructure/terraform/envs/production/terraform.tfvars"}

if [ ! -f "$FILE_PATH" ]; then
    echo "Error: $FILE_PATH not found."
    exit 1
fi

# Function to create or update a secret in GCP
push_secret() {
    local key=$1
    local value=$2
    
    echo "Processing $key..."
    
    # Check if secret exists
    if ! gcloud secrets describe "$key" &>/dev/null; then
        echo "Creating secret $key..."
        gcloud secrets create "$key" --replication-policy="automatic"
    fi
    
    # Add new version
    echo -n "$value" | gcloud secrets versions add "$key" --data-file=-
}

# Parse tfvars file (simple key="value" parsing)
while IFS= read -r line; do
    # Skip comments and empty lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "$line" ]] && continue
    
    if [[ "$line" =~ ^([a-zA-Z0-9_]+)[[:space:]]*=[[:space:]]*\"(.*)\" ]]; then
        key="${BASH_REMATCH[1]}"
        value="${BASH_REMATCH[2]}"
        
        # Only migrate secrets (you can filter by common secret names)
        case "$key" in
            *password*|*token*|*secret*|*api_key*|*credentials*)
                push_secret "$key" "$value"
                ;;
            *)
                # Skip non-secrets
                ;;
        esac
    fi
done < "$FILE_PATH"

echo "Migration complete."
