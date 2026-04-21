#!/bin/bash
# scripts/bootstrap-coolify.sh
# Bootstraps Coolify after VM provisioning.
# Gets API token, destination UUID, and updates Secret Manager.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Load variables from environment or use defaults
PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
VM_NAME="${APP_NAME:-nexaduo-chat-services}"
ZONE="${GCP_ZONE:-us-central1-b}"
SSH_USER="${SSH_USER:-ubuntu}"
DEFAULT_EMAIL="${COOLIFY_BOOTSTRAP_EMAIL:-admin@nexaduo.local}"
DEFAULT_PASSWORD="${COOLIFY_BOOTSTRAP_PASSWORD:-$(openssl rand -hex 16)}"

if [ -z "${COOLIFY_BOOTSTRAP_PASSWORD:-}" ]; then
  echo "INFO: COOLIFY_BOOTSTRAP_PASSWORD not provided; using generated one-time bootstrap password."
fi

# Helper: Ensure secret exists in Secret Manager
ensure_secret() {
  local secret_name=$1
  if ! gcloud secrets describe "$secret_name" --project "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Creating secret: $secret_name"
    gcloud secrets create "$secret_name" --project "$PROJECT_ID" --replication-policy="automatic"
  fi
}

# 0. Pre-flight Checks
echo "Running pre-flight checks..."
if ! command -v gcloud &> /dev/null; then
    echo "Error: gcloud CLI is not installed."
    exit 1
fi

# Verify GCP project access
if ! gcloud projects describe "$PROJECT_ID" >/dev/null 2>&1; then
    echo "Error: Cannot access GCP project $PROJECT_ID. Check authentication and project ID."
    exit 1
fi
echo "Pre-flight checks passed."

# 1. Get VM IP
echo "Fetching VM IP for instance $VM_NAME..."
VM_IP=$(gcloud compute instances describe "$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --format='get(networkInterfaces[0].accessConfigs[0].natIP)')

if [ -z "$VM_IP" ]; then
  echo "Error: Could not find public IP for instance $VM_NAME"
  exit 1
fi
echo "VM IP: $VM_IP"

# 2. Wait for Coolify API to be ready
echo "Waiting for Coolify API to be ready at http://$VM_IP:8000/api/v1/version..."
MAX_RETRIES=30
RETRY_INTERVAL=10
COUNT=0
until curl -s "http://$VM_IP:8000/api/v1/version" > /dev/null; do
  COUNT=$((COUNT + 1))
  if [ $COUNT -ge $MAX_RETRIES ]; then
    echo "Error: Coolify API did not become ready in time."
    exit 1
  fi
  echo "Retry $COUNT/$MAX_RETRIES..."
  sleep $RETRY_INTERVAL
done
echo "Coolify API is ready."

# 3. Create Admin User and Generate API Token via Tinker
echo "Ensuring Admin user and generating Coolify API token via Tinker..."
# We create a user and a team (if they don't exist), then generate a Sanctum token.
# Coolify requires a team_id for personal_access_tokens.
TINKER_CMD=$(cat <<'PHP'
$user = App\Models\User::find(0);
if (!$user) {
    $user = App\Models\User::where("email", "__EMAIL__")->first();
}
if (!$user) {
    $user = new App\Models\User();
    $user->name = "Admin";
    $user->email = "__EMAIL__";
    $user->password = Hash::make("__PASSWORD__");
    $user->email_verified_at = now();
    $user->save();
}

$team = App\Models\Team::find(0);
if (!$team) {
    $team = $user->teams()->first();
}
if (!$team) {
    $team = App\Models\Team::where("name", "Admin Team")->first();
}
if (!$team) {
    $team = App\Models\Team::create(["name" => "Admin Team", "personal_team" => true]);
}

if (!$user->teams()->where("teams.id", $team->id)->exists()) {
    $user->teams()->attach($team->id, ["role" => "owner"]);
}

// Enable API in settings
$settings = App\Models\InstanceSettings::first();
if ($settings) {
    $settings->is_api_enabled = true;
    $settings->save();
}
// Ensure localhost server is attached to the same team used by API token
$server = App\Models\Server::where("name", "localhost")->first();
if ($server && $server->team_id != $team->id) {
    $server->team_id = $team->id;
    $server->save();
}
// Generate token in the provider-expected "id|token" Sanctum format
$plainToken = Str::random(40);
$token = $user->tokens()->create([
    "name" => "Bootstrap Token",
    "token" => hash("sha256", $plainToken),
    "abilities" => ["*"],
    "team_id" => $team->id,
]);
print($token->id . "|" . $plainToken);
PHP
)
TINKER_CMD="${TINKER_CMD//__EMAIL__/${DEFAULT_EMAIL}}"
TINKER_CMD="${TINKER_CMD//__PASSWORD__/${DEFAULT_PASSWORD}}"

# Run Tinker command via SSH IAP
COOLIFY_TOKEN=$(gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --command "sudo docker exec coolify php artisan tinker --execute '$TINKER_CMD'" 2>/dev/null)

if [[ "$COOLIFY_TOKEN" == *"Error"* ]] || [ -z "$COOLIFY_TOKEN" ]; then
  echo "Error: Failed to generate Coolify API token."
  exit 1
fi

# Clean up token output (remove gcloud warnings/logs)
COOLIFY_TOKEN=$(echo "$COOLIFY_TOKEN" | grep -v "WARNING" | grep -v "To increase" | grep -v "please see" | xargs)
echo "Token generated successfully (hidden)."

# 4. Create and Get Destination UUID via Tinker
echo "Ensuring destination 'nexaduo-network' via Tinker..."
DEST_TINKER_CMD='
$dest = App\Models\StandaloneDocker::where("network", "nexaduo-network")->first();
if (!$dest) {
    $dest = new App\Models\StandaloneDocker();
    $dest->name = "nexaduo-network";
    $dest->network = "nexaduo-network";
    $dest->server_id = 0;
    $dest->save();
}
print($dest->uuid);
'
DESTINATION_UUID=$(gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --command "sudo docker exec coolify php artisan tinker --execute '$DEST_TINKER_CMD'" 2>/dev/null)

DESTINATION_UUID=$(echo "$DESTINATION_UUID" | grep -v "WARNING" | grep -v "To increase" | grep -v "please see" | xargs)

if [ -z "$DESTINATION_UUID" ]; then
  echo "Error: Could not find/create destination UUID."
  exit 1
fi
echo "Destination UUID: $DESTINATION_UUID"

# 5. Update GCP Secret Manager
echo "Updating Secret Manager (SSOT)..."
ensure_secret "coolify_api_token"
echo -n "$COOLIFY_TOKEN" | gcloud secrets versions add coolify_api_token \
  --project "$PROJECT_ID" --data-file=- >/dev/null

ensure_secret "coolify_destination_uuid"
echo -n "$DESTINATION_UUID" | gcloud secrets versions add coolify_destination_uuid \
  --project "$PROJECT_ID" --data-file=- >/dev/null

ensure_secret "coolify_url"
echo -n "http://$VM_IP:8000/api/v1" | gcloud secrets versions add coolify_url \
  --project "$PROJECT_ID" --data-file=- >/dev/null

echo "Secret Manager updated with new token, destination UUID, and URL."

# 6. Upload 01-init.sql
echo "Uploading 01-init.sql to VM..."
INIT_SQL_PATH="${PROJECT_ROOT}/deploy/01-init.sql"
if [ ! -f "${INIT_SQL_PATH}" ]; then
  echo "Warning: file not found: ${INIT_SQL_PATH}. Skipping upload."
else
  # Wait for IAP to be ready
  sleep 5
  gcloud compute scp \
    --tunnel-through-iap \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    "${INIT_SQL_PATH}" \
    "$SSH_USER@$VM_NAME:/tmp/01-init.sql" >/dev/null 2>&1

  gcloud compute ssh \
    --tunnel-through-iap \
    --project "$PROJECT_ID" \
    --zone "$ZONE" \
    "$SSH_USER@$VM_NAME" \
    --command "sudo mkdir -p /opt/nexaduo/postgres && sudo mv /tmp/01-init.sql /opt/nexaduo/postgres/01-init.sql && sudo chown -R $SSH_USER:$SSH_USER /opt/nexaduo" >/dev/null 2>&1
  echo "01-init.sql uploaded to /opt/nexaduo/postgres/01-init.sql"
fi

# 7. Create Docker network
echo "Ensuring Docker network 'nexaduo-network'..."
gcloud compute ssh \
  --tunnel-through-iap \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  "$SSH_USER@$VM_NAME" \
  --command "sudo docker network inspect nexaduo-network >/dev/null 2>&1 || sudo docker network create nexaduo-network" >/dev/null 2>&1

echo "Bootstrap complete! The Tenant layer can now be deployed."
