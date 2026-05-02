#!/usr/bin/env bash
# scripts/deploy-tenant-direct.sh
#
# Bypasses the flaky Coolify Terraform provider to deploy the application stack
# directly via SCP and SSH, with correct Coolify labels AND container names.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${PROJECT_ROOT}/infrastructure/terraform/envs/production/terraform.tfvars"

# Configuration
PROJECT_ID=$(grep "gcp_project_id" "${TFVARS}" | cut -d'"' -f2)
ZONE=$(grep "gcp_region" "${TFVARS}" | cut -d'"' -f2)-b
VM_NAME=$(grep "app_name" "${TFVARS}" | cut -d'"' -f2)
SSH_USER=$(grep "ssh_user" "${TFVARS}" | cut -d'"' -f2)

# Coolify Project UUIDs
UUID_SHARED="cptudr03mfpifug3rsdjet41"
UUID_CHATWOOT="rl3esrvnj7pfww9y25j8okhy"
UUID_DIFY="e2h1z9nbliudddkpuigs0igt"
UUID_NEXADUO="kh0g7bovvsmtf9riyocndet3"

fetch_secret() {
  gcloud secrets versions access latest --secret="$1" --project="${PROJECT_ID}"
}

echo "=== Fetching secrets from GCP Secret Manager ==="
POSTGRES_PASSWORD=$(fetch_secret "postgres_password")
REDIS_PASSWORD=$(fetch_secret "redis_password")
TUNNEL_TOKEN=$(fetch_secret "tunnel_token")
CHATWOOT_SECRET_KEY_BASE=$(fetch_secret "chatwoot_secret_key_base")
DIFY_SECRET_KEY=$(fetch_secret "dify_secret_key")
DIFY_SANDBOX_API_KEY=$(fetch_secret "dify_sandbox_api_key")
DIFY_PLUGIN_DAEMON_KEY=$(fetch_secret "dify_plugin_daemon_key")
DIFY_PLUGIN_DIFY_INNER_API_KEY=$(fetch_secret "dify_plugin_dify_inner_api_key")
EVOLUTION_API_KEY=$(fetch_secret "evolution_authentication_api_key")
CHATWOOT_API_TOKEN=$(fetch_secret "chatwoot_api_token")
HANDOFF_SECRET=$(fetch_secret "handoff_shared_secret")
GRAFANA_PASSWORD=$(fetch_secret "grafana_admin_password")
GOOGLE_ID=$(fetch_secret "google_oauth_client_id")
GOOGLE_SECRET=$(fetch_secret "google_oauth_client_secret")

# Images from tfvars
MIDDLEWARE_IMAGE=$(grep "middleware_image" "${TFVARS}" | cut -d'"' -f2)
SELF_HEALING_IMAGE=$(grep "self_healing_image" "${TFVARS}" | cut -d'"' -f2)

# --- Shared Stack (UUID: cptudr03mfpifug3rsdjet41) ---
cat <<EOF > /tmp/shared.yml
services:
  postgres:
    image: pgvector/pgvector:pg16
    container_name: cs631ankndt6k0bizgwijxe0
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD}'
      POSTGRES_DB: postgres
    labels:
      coolify.managed: "true"
      coolify.serviceId: "1"
    networks:
      - chat-network
  redis:
    image: redis:7.2.4-alpine
    container_name: scke42coegs5p4h7gnb8kq10
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    labels:
      coolify.managed: "true"
      coolify.serviceId: "1"
    networks:
      - chat-network
  cloudflared:
    image: cloudflare/cloudflared:latest
    container_name: ugv5vxwujt829w2yy7uvslgd
    restart: unless-stopped
    command: tunnel run
    environment:
      TUNNEL_TOKEN: '${TUNNEL_TOKEN}'
    labels:
      coolify.managed: "true"
      coolify.serviceId: "1"
    networks:
      - chat-network
networks:
  chat-network:
    external: true
    name: nexaduo-network
EOF

# --- Chatwoot Stack (UUID: rl3esrvnj7pfww9y25j8okhy) ---
cat <<EOF > /tmp/chatwoot.yml
services:
  chatwoot-rails:
    image: chatwoot/chatwoot:v4.13.0-ce
    container_name: kwcwx8psjfytawza93ob3fu2
    restart: unless-stopped
    environment:
      NODE_ENV: production
      RAILS_ENV: production
      INSTALLATION_ENV: docker
      SECRET_KEY_BASE: '${CHATWOOT_SECRET_KEY_BASE}'
      FRONTEND_URL: https://chat.nexaduo.com
      POSTGRES_HOST: postgres
      POSTGRES_USERNAME: postgres
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD}'
      POSTGRES_DATABASE: chatwoot
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      CHATWOOT_FORCE_SSL: "false"
      FORCE_SSL: "false"
      GOOGLE_OAUTH_CLIENT_ID: '${GOOGLE_ID}'
      GOOGLE_OAUTH_CLIENT_SECRET: '${GOOGLE_SECRET}'
      GOOGLE_OAUTH_CALLBACK_URL: https://chat.nexaduo.com/omniauth/google_oauth2/callback
    labels:
      coolify.managed: "true"
      coolify.serviceId: "2"
    entrypoint: docker/entrypoints/rails.sh
    command: ["bundle", "exec", "rails", "s", "-p", "3000", "-b", "0.0.0.0"]
    networks:
      - chat-network
  chatwoot-sidekiq:
    image: chatwoot/chatwoot:v4.13.0-ce
    container_name: y5zliphtugysywg7l90wiugo
    restart: unless-stopped
    environment:
      NODE_ENV: production
      RAILS_ENV: production
      INSTALLATION_ENV: docker
      SECRET_KEY_BASE: '${CHATWOOT_SECRET_KEY_BASE}'
      POSTGRES_HOST: postgres
      POSTGRES_USERNAME: postgres
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD}'
      POSTGRES_DATABASE: chatwoot
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
    labels:
      coolify.managed: "true"
      coolify.serviceId: "2"
    command: ["bundle", "exec", "sidekiq", "-C", "config/sidekiq.yml"]
    networks:
      - chat-network
networks:
  chat-network:
    external: true
    name: nexaduo-network
EOF

# --- Dify Stack (UUID: e2h1z9nbliudddkpuigs0igt) ---
cat <<EOF > /tmp/dify.yml
services:
  dify-api:
    image: langgenius/dify-api:1.13.3
    container_name: eoxoa4q2v1abcgd0fw0jgz6o
    restart: unless-stopped
    environment:
      POSTGRES_HOST: postgres
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD}'
      REDIS_PASSWORD: '${REDIS_PASSWORD}'
      DIFY_SECRET_KEY: '${DIFY_SECRET_KEY}'
    labels:
      coolify.managed: "true"
      coolify.serviceId: "3"
    networks:
      - chat-network
  dify-web:
    image: langgenius/dify-web:1.13.3
    container_name: zuqklqrp6qgiidmg7l08h74e
    restart: unless-stopped
    labels:
      coolify.managed: "true"
      coolify.serviceId: "3"
    networks:
      - chat-network
  dify-worker:
    image: langgenius/dify-api:1.13.3
    container_name: vi23kenjpx7wpzqwtb7z8i2d
    restart: unless-stopped
    labels:
      coolify.managed: "true"
      coolify.serviceId: "3"
    networks:
      - chat-network
networks:
  chat-network:
    external: true
    name: nexaduo-network
EOF

# --- NexaDuo Stack (UUID: kh0g7bovvsmtf9riyocndet3) ---
cat <<EOF > /tmp/nexaduo.yml
services:
  evolution-api:
    image: atendai/evolution-api:v2.1.1
    container_name: d14aypqa2k5op2ezd3naia76
    restart: unless-stopped
    environment:
      AUTHENTICATION_API_KEY: '${EVOLUTION_API_KEY}'
      DATABASE_CONNECTION_URI: 'postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/evolution'
    labels:
      coolify.managed: "true"
      coolify.serviceId: "4"
    networks:
      - chat-network
  middleware:
    image: '${MIDDLEWARE_IMAGE}'
    container_name: zhuahbecpn9v39g707gmltku
    restart: unless-stopped
    environment:
      CHATWOOT_API_TOKEN: '${CHATWOOT_API_TOKEN}'
      HANDOFF_SHARED_SECRET: '${HANDOFF_SECRET}'
    labels:
      coolify.managed: "true"
      coolify.serviceId: "4"
    networks:
      - chat-network
  self-healing-agent:
    image: '${SELF_HEALING_IMAGE}'
    container_name: fdidkia1e1u4e2m43spd0z51
    restart: unless-stopped
    environment:
      DATABASE_URL: 'postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/self_healing'
      HANDOFF_SHARED_SECRET: '${HANDOFF_SECRET}'
    labels:
      coolify.managed: "true"
      coolify.serviceId: "4"
    networks:
      - chat-network
  grafana:
    image: grafana/grafana:11.3.0
    container_name: ab9i20xcwqw8xqzu99vh4rkr
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_PASSWORD: '${GRAFANA_PASSWORD}'
    labels:
      coolify.managed: "true"
      coolify.serviceId: "4"
    networks:
      - chat-network
networks:
  chat-network:
    external: true
    name: nexaduo-network
EOF

deploy_to_vm() {
  local uuid=$1 local_file=$2
  echo "--- Deploying ${uuid} ---"
  gcloud compute scp --tunnel-through-iap --project="${PROJECT_ID}" --zone="${ZONE}" \
    "${local_file}" "${SSH_USER}@${VM_NAME}:/tmp/${uuid}.yml"
  
  gcloud compute ssh "${SSH_USER}@${VM_NAME}" --project="${PROJECT_ID}" --zone="${ZONE}" --tunnel-through-iap \
    --command "sudo mkdir -p /data/coolify/services/${uuid} && \
               sudo mv /tmp/${uuid}.yml /data/coolify/services/${uuid}/docker-compose.yml && \
               sudo bash -c 'cd /data/coolify/services/${uuid} && docker compose up -d --remove-orphans'"
}

deploy_to_vm "${UUID_SHARED}" "/tmp/shared.yml"
deploy_to_vm "${UUID_CHATWOOT}" "/tmp/chatwoot.yml"
deploy_to_vm "${UUID_DIFY}" "/tmp/dify.yml"
deploy_to_vm "${UUID_NEXADUO}" "/tmp/nexaduo.yml"

echo "=== Redeployed with UUID-based container names to fix Coolify status. ==="
