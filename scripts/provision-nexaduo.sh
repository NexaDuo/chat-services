#!/usr/bin/env bash
# scripts/provision-nexaduo.sh
#
# Creates the initial 'nexaduo' tenant in the shared database.

set -euo pipefail

PROJECT_ID="nexaduo-492818"

echo "=== Provisioning 'nexaduo' tenant in shared DB ==="

# Insert tenant into middleware database
gcloud compute ssh ubuntu@nexaduo-chat-services --project="${PROJECT_ID}" --zone="us-central1-b" --tunnel-through-iap --quiet \
  --command "sudo docker exec o8oesqqa4v0zntps6e3x7sw2-postgres-1 psql -U postgres -d postgres -c \"
    INSERT INTO tenants (slug, name, dify_api_key, status) 
    VALUES ('nexaduo', 'NexaDuo Main', 'dummy-key', 'active')
    ON CONFLICT (slug) DO NOTHING;
  \""

echo "Provisioning complete."
