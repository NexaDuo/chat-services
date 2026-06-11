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
DEFAULT_EMAIL="${COOLIFY_BOOTSTRAP_EMAIL:-alexandre@nexaduo.com}"
DEFAULT_PASSWORD="${COOLIFY_BOOTSTRAP_PASSWORD:-}"

# Fetch admin_password if not provided (Unified Login)
if [ -z "$DEFAULT_PASSWORD" ]; then
  echo "Fetching unified admin_password from Secret Manager..."
  DEFAULT_PASSWORD=$(gcloud secrets versions access latest --secret=admin_password --project="$PROJECT_ID" 2>/dev/null || echo "")
  if [ -z "$DEFAULT_PASSWORD" ]; then
    echo "Warning: Unified admin_password secret not found. Generating temporary one."
    DEFAULT_PASSWORD="$(openssl rand -hex 16)"
  fi
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
TINKER_CMD=$(cat <<'PHP'
$user = App\Models\User::where("email", "__EMAIL__")->first();
if (!$user) {
    $user = new App\Models\User();
    $user->name = "Admin";
    $user->email = "__EMAIL__";
    $user->password = Hash::make("__PASSWORD__");
    $user->email_verified_at = now();
    $user->save();
}

$team = App\Models\Team::where("name", "Admin Team")->first();
if (!$team) {
    $team = App\Models\Team::create(["name" => "Admin Team", "personal_team" => true]);
}

if (!$user->teams()->where("teams.id", $team->id)->exists()) {
    $user->teams()->attach($team->id, ["role" => "owner"]);
}

// Enable API and Configure FQDN (HTTP to avoid Traefik loop)
$settings = App\Models\InstanceSettings::first();
if ($settings) {
    $settings->is_api_enabled = true;
    $settings->fqdn = "http://coolify.nexaduo.com";
    $settings->save();
}

// FIX: Ensure localhost server and its key are attached to the same team and use ubuntu
$server = App\Models\Server::where("name", "localhost")->first();
if ($server) {
    $server->team_id = $team->id;
    $server->user = "ubuntu";
    $server->save();
    
    $privateKey = App\Models\PrivateKey::find($server->private_key_id);
    if ($privateKey) {
        $privateKey->team_id = $team->id;
        $privateKey->save();
    }
    
    // Disable internal redirect (Cloudflare handles it)
    if ($server->proxy) {
        $proxy = $server->proxy;
        $proxy["redirect_enabled"] = false;
        $server->proxy = $proxy;
        $server->save();
    }
}

// Generate Sanctum token
$plainToken = Str::random(40);
$token = $user->tokens()->create([
    "name" => "Bootstrap Token",
    "token" => hash("sha256", $plainToken),
    "abilities" => ["*"],
    "team_id" => $team->id,
]);
print("BOOTSTRAP_RESULT:" . $token->id . "|" . $plainToken);
PHP
)
TINKER_CMD="${TINKER_CMD//__EMAIL__/${DEFAULT_EMAIL}}"
TINKER_CMD="${TINKER_CMD//__PASSWORD__/${DEFAULT_PASSWORD}}"

COOLIFY_RAW_OUTPUT=$(gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --command "sudo docker exec coolify php artisan tinker --execute '$TINKER_CMD'")

COOLIFY_TOKEN=$(echo "$COOLIFY_RAW_OUTPUT" | grep "BOOTSTRAP_RESULT:" | sed 's/BOOTSTRAP_RESULT://' | tr -d '\r' | tr -d '\n')

if [ -z "$COOLIFY_TOKEN" ]; then
  echo "Error: Failed to generate Coolify API token. Raw output:"
  echo "$COOLIFY_RAW_OUTPUT"
  exit 1
fi
echo "Token generated successfully (hidden)."

# 3b. Authorize Coolify SSH key and fix group permissions
echo "Fixing SSH authorization and Docker permissions on host..."
gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --command '
    sudo usermod -aG docker ubuntu
    sudo chgrp -R docker /data/coolify
    sudo chmod -R g+rX /data/coolify
    echo "Waiting for Coolify to generate SSH key..."
    for i in $(seq 1 30); do
      PRIV_KEY_FILE=$(sudo find /data/coolify/ssh/keys -name "ssh_key*" ! -name "*.lock" | head -n 1)
      if [ -n "$PRIV_KEY_FILE" ]; then
        break
      fi
      sleep 2
    done
    if [ -n "$PRIV_KEY_FILE" ]; then
      PUB_KEY=$(sudo ssh-keygen -y -f "$PRIV_KEY_FILE")
      echo "$PUB_KEY coolify-internal" | sudo tee -a /home/ubuntu/.ssh/authorized_keys > /dev/null
      sudo docker exec coolify sh -c "mkdir -p /home/www-data/.ssh && ssh-keyscan -H host.docker.internal >> /home/www-data/.ssh/known_hosts && chown -R 9999:9999 /home/www-data/.ssh"
      echo "Coolify SSH key authorized."
    else
      echo "Error: Coolify SSH key was not generated in time." >&2
      exit 1
    fi
  '

# 3c. Upload Postgres init SQL and observability configs to the VM.
# The shared/observability composes bind-mount these paths; if the host files
# are absent when a container starts, Docker creates them as DIRECTORIES,
# which breaks Postgres (01-init.sql) and Loki/Prometheus/Promtail. Seeding
# them here (bootstrap runs before the tenant deploy) keeps them as files.
echo "Uploading 01-init.sql and observability configs to the VM..."
SEED_TMP="$(mktemp -d)"
cp "${PROJECT_ROOT}/infrastructure/postgres/01-init.sql" "${SEED_TMP}/01-init.sql"
cp -r "${PROJECT_ROOT}/observability" "${SEED_TMP}/observability"
tar -C "${SEED_TMP}" -czf "${SEED_TMP}/seed.tar.gz" 01-init.sql observability
gcloud compute scp \
  --project "$PROJECT_ID" --zone "$ZONE" --tunnel-through-iap --quiet \
  "${SEED_TMP}/seed.tar.gz" "$SSH_USER@$VM_NAME:/tmp/seed.tar.gz"
gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" --zone "$ZONE" --tunnel-through-iap --quiet \
  --command '
    sudo tar -C /tmp -xzf /tmp/seed.tar.gz
    sudo mkdir -p /opt/nexaduo/postgres
    sudo rm -rf /opt/nexaduo/postgres/01-init.sql
    sudo mv /tmp/01-init.sql /opt/nexaduo/postgres/01-init.sql
    sudo rm -rf /opt/nexaduo/observability
    sudo mv /tmp/observability /opt/nexaduo/observability
    rm -f /tmp/seed.tar.gz
    echo "Seeded: $(sudo stat -c %F /opt/nexaduo/postgres/01-init.sql) 01-init.sql"
  '
rm -rf "${SEED_TMP}"

# 3d. Authenticate Docker against Artifact Registry on the VM.
# The nexaduo stack pulls private images (middleware, self-healing-agent). The
# VM SA has artifactregistry.reader, but Docker needs the gcloud credential
# helper configured or `docker compose up` aborts with "Unauthenticated request".
echo "Configuring Docker auth for Artifact Registry on the VM..."
gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" --zone "$ZONE" --tunnel-through-iap --quiet \
  --command "sudo gcloud auth configure-docker ${GCP_REGION:-us-central1}-docker.pkg.dev --quiet"

# 3e. Install the daily Postgres backup cron on the VM.
# The stack has no backups otherwise (scripts/backup.sh is local-dev only and
# was never wired). We upload scripts/vm-backup.sh (container/DB-agnostic) and
# register a root cron that dumps every DB nightly to the GCS backup bucket.
# Idempotent: the existing cron line is stripped before re-adding.
BACKUP_BUCKET="${BACKUP_BUCKET:-nexaduo-coolify-backups}"
echo "Installing daily backup cron on the VM (bucket: ${BACKUP_BUCKET})..."
gcloud compute scp \
  --project "$PROJECT_ID" --zone "$ZONE" --tunnel-through-iap --quiet \
  "${PROJECT_ROOT}/scripts/vm-backup.sh" "$SSH_USER@$VM_NAME:/tmp/vm-backup.sh"
gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" --zone "$ZONE" --tunnel-through-iap --quiet \
  --command "
    sudo mkdir -p /opt/nexaduo/backups
    sudo mv /tmp/vm-backup.sh /opt/nexaduo/vm-backup.sh
    sudo chmod +x /opt/nexaduo/vm-backup.sh
    CRON_LINE='0 3 * * * BACKUP_BUCKET=${BACKUP_BUCKET} /opt/nexaduo/vm-backup.sh >> /var/log/nexaduo-backup.log 2>&1'
    ( sudo crontab -l 2>/dev/null | grep -vF '/opt/nexaduo/vm-backup.sh'; echo \"\$CRON_LINE\" ) | sudo crontab -
    echo 'Backup cron installed:'; sudo crontab -l | grep vm-backup.sh
  "

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
print("DEST_RESULT:" . $dest->uuid);
'
DESTINATION_RAW_OUTPUT=$(gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --command "sudo docker exec coolify php artisan tinker --execute '$DEST_TINKER_CMD'")

DESTINATION_UUID=$(echo "$DESTINATION_RAW_OUTPUT" | grep "DEST_RESULT:" | sed 's/DEST_RESULT://' | tr -d '\r' | tr -d '\n')

if [ -z "$DESTINATION_UUID" ]; then
  echo "Error: Failed to get Destination UUID. Raw output:"
  echo "$DESTINATION_RAW_OUTPUT"
  exit 1
fi
echo "Destination UUID: $DESTINATION_UUID"

# 5. Update Secret Manager
echo "Updating Secret Manager..."
ensure_secret "coolify_api_token"
echo -n "$COOLIFY_TOKEN" | gcloud secrets versions add coolify_api_token --project "$PROJECT_ID" --data-file=- --quiet >/dev/null
ensure_secret "coolify_destination_uuid"
echo -n "$DESTINATION_UUID" | gcloud secrets versions add coolify_destination_uuid --project "$PROJECT_ID" --data-file=- --quiet >/dev/null
ensure_secret "coolify_url"
echo -n "http://$VM_IP:8000/api/v1" | gcloud secrets versions add coolify_url --project "$PROJECT_ID" --data-file=- --quiet >/dev/null

# 6. Final cleanup and status refresh
echo "Forcing service status refresh..."
gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --command "sudo docker exec coolify-db psql -U coolify -d coolify -c \"UPDATE service_applications SET status = 'running';\" && sudo docker restart coolify"

echo "Bootstrap complete!"
