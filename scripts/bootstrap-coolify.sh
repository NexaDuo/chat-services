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

# 2b. Ensure a persistent swapfile on the VM.
# The full stack + a Coolify `php artisan tinker` invocation exceeds the 8 GB
# staging VM RAM and gets OOM-killed (exit 137) without swap. A 4 GB swapfile
# (persisted in /etc/fstab so it survives reboots / power-cycles) lets the Tinker
# steps fit. Idempotent: no-op once /swapfile exists and is active.
echo "Ensuring swapfile is present and active..."
gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --quiet \
  --command 'if ! sudo swapon --show | grep -q /swapfile; then
      sudo fallocate -l 4G /swapfile || sudo dd if=/dev/zero of=/swapfile bs=1M count=4096;
      sudo chmod 600 /swapfile;
      sudo mkswap /swapfile;
      sudo swapon /swapfile;
      grep -q /swapfile /etc/fstab || echo /swapfile none swap sw 0 0 | sudo tee -a /etc/fstab;
    fi;
    sudo swapon --show'

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
    sudo sysctl vm.overcommit_memory=1
    echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf
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
echo "Uploading 01-init.sql, observability configs, and Chatwoot initializers to the VM..."
SEED_TMP="$(mktemp -d)"
cp "${PROJECT_ROOT}/infrastructure/postgres/01-init.sql" "${SEED_TMP}/01-init.sql"
cp -r "${PROJECT_ROOT}/observability" "${SEED_TMP}/observability"
mkdir -p "${SEED_TMP}/deploy"
cp "${PROJECT_ROOT}/deploy/ai_agents.rb" "${SEED_TMP}/deploy/ai_agents.rb"
tar -C "${SEED_TMP}" -czf "${SEED_TMP}/seed.tar.gz" 01-init.sql observability deploy
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

    sudo mkdir -p /opt/nexaduo/deploy
    sudo rm -rf /opt/nexaduo/deploy/ai_agents.rb
    sudo mv /tmp/deploy/ai_agents.rb /opt/nexaduo/deploy/ai_agents.rb

    # Observability configs are bind-mounted into their containers and read only
    # at startup; replacing the observability dir below swaps its inode, so a
    # running consumer keeps its old config. Capture the CONTENT hash of each
    # incoming config now (path-independent: we keep only column 1 of sha256sum),
    # persist it outside the swapped dir, and restart a running consumer iff its
    # shipped config actually changed -- no churn on no-op deploys. Services not
    # yet running (e.g. a brand-new tempo/otel-collector before the tenant deploy)
    # are simply skipped and start fresh with the new config.
    SUMS=/opt/nexaduo/.obs-checksums
    sudo mkdir -p "$SUMS"
    NEW_PROMTAIL_SHA="$(sha256sum /tmp/observability/promtail/promtail.yaml 2>/dev/null | awk "{print \$1}")"
    NEW_OTELCOL_SHA="$(sha256sum /tmp/observability/otel-collector/config.yaml 2>/dev/null | awk "{print \$1}")"
    NEW_TEMPO_SHA="$(sha256sum /tmp/observability/tempo/tempo.yaml 2>/dev/null | awk "{print \$1}")"
    NEW_LOKI_SHA="$(sha256sum /tmp/observability/loki/loki.yaml 2>/dev/null | awk "{print \$1}")"
    NEW_PROM_SHA="$(sha256sum /tmp/observability/prometheus/prometheus.yml 2>/dev/null | awk "{print \$1}")"
    NEW_GRAFANA_SHA="$(find /tmp/observability/grafana/provisioning -type f -exec sha256sum {} + 2>/dev/null | awk "{print \$1}" | sort | sha256sum | awk "{print \$1}")"

    sudo rm -rf /opt/nexaduo/observability
    sudo mv /tmp/observability /opt/nexaduo/observability
    rm -f /tmp/seed.tar.gz

    obs_restart_if_changed() {
      svc="$1"; new="$2"; marker="$SUMS/$svc.sha"
      [ -z "$new" ] && return 0
      old="$(sudo cat "$marker" 2>/dev/null || true)"
      printf "%s\n" "$new" | sudo tee "$marker" >/dev/null
      [ "$new" = "$old" ] && return 0
      c="$(sudo docker ps --filter name="$svc" --format "{{.Names}}" | head -1)"
      [ -z "$c" ] && return 0
      echo "Observability config for $c changed; restarting to reload."
      sudo docker restart "$c" >/dev/null || true
    }
    obs_restart_if_changed promtail "$NEW_PROMTAIL_SHA"
    obs_restart_if_changed otel-collector "$NEW_OTELCOL_SHA"
    obs_restart_if_changed tempo "$NEW_TEMPO_SHA"
    obs_restart_if_changed loki "$NEW_LOKI_SHA"
    obs_restart_if_changed prometheus "$NEW_PROM_SHA"
    obs_restart_if_changed grafana "$NEW_GRAFANA_SHA"

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

# 5. Update Secret Manager (per-environment, so a staging deploy never clobbers
#    production's Coolify connection secrets — and vice-versa).
ENVIRONMENT="${ENVIRONMENT:-production}"
echo "Updating Secret Manager (env=${ENVIRONMENT})..."
ensure_secret "coolify_api_token_${ENVIRONMENT}"
echo -n "$COOLIFY_TOKEN" | gcloud secrets versions add "coolify_api_token_${ENVIRONMENT}" --project "$PROJECT_ID" --data-file=- --quiet >/dev/null
ensure_secret "coolify_destination_uuid_${ENVIRONMENT}"
echo -n "$DESTINATION_UUID" | gcloud secrets versions add "coolify_destination_uuid_${ENVIRONMENT}" --project "$PROJECT_ID" --data-file=- --quiet >/dev/null
ensure_secret "coolify_url_${ENVIRONMENT}"
echo -n "http://$VM_IP:8000/api/v1" | gcloud secrets versions add "coolify_url_${ENVIRONMENT}" --project "$PROJECT_ID" --data-file=- --quiet >/dev/null

# 6. Final cleanup and status refresh
echo "Forcing service status refresh..."
gcloud compute ssh "$SSH_USER@$VM_NAME" \
  --project "$PROJECT_ID" \
  --zone "$ZONE" \
  --tunnel-through-iap \
  --command "sudo docker exec coolify-db psql -U coolify -d coolify -c \"UPDATE service_applications SET status = 'running';\" && sudo docker restart coolify"

echo "Bootstrap complete!"
