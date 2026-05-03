#!/usr/bin/env bash
# scripts/deploy-tenant-direct.sh
#
# Bypasses the flaky Coolify Terraform provider to deploy the application stack
# directly via SCP and SSH, with correct Coolify labels and container names.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TFVARS="${PROJECT_ROOT}/infrastructure/terraform/envs/production/terraform.tfvars"

# Configuration
PROJECT_ID=$(grep "gcp_project_id" "${TFVARS}" | cut -d'"' -f2)
ZONE=$(grep "gcp_region" "${TFVARS}" | cut -d'"' -f2)-b
VM_NAME=$(grep "app_name" "${TFVARS}" | cut -d'"' -f2)
SSH_USER=$(grep "ssh_user" "${TFVARS}" | cut -d'"' -f2)

# Coolify IDs and Names
PROJECT_NAME="NexaDuo Chat Services"
ENV_NAME="production"

# Service UUIDs (Projects)
UUID_SHARED="cptudr03mfpifug3rsdjet41"; ID_SHARED="1"
UUID_CHATWOOT="rl3esrvnj7pfww9y25j8okhy"; ID_CHATWOOT="2"
UUID_DIFY="e2h1z9nbliudddkpuigs0igt"; ID_DIFY="3"
UUID_NEXADUO="kh0g7bovvsmtf9riyocndet3"; ID_NEXADUO="4"

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
CHATWOOT_WEBHOOK_TOKEN=""
HANDOFF_SECRET=$(fetch_secret "handoff_shared_secret")
GRAFANA_PASSWORD=$(fetch_secret "grafana_admin_password")
GOOGLE_ID=$(fetch_secret "google_oauth_client_id")
GOOGLE_SECRET=$(fetch_secret "google_oauth_client_secret")

# Images from tfvars
MIDDLEWARE_IMAGE=$(grep "middleware_image" "${TFVARS}" | cut -d'"' -f2)
SELF_HEALING_IMAGE=$(grep "self_healing_image" "${TFVARS}" | cut -d'"' -f2)

# Common labels function
labels() {
  local service_id=$1 sub_name=$2 resource_name=$3
  cat <<EOF
      coolify.managed: "true"
      coolify.type: "service"
      coolify.projectName: "${PROJECT_NAME}"
      coolify.environmentName: "${ENV_NAME}"
      coolify.serviceId: "${service_id}"
      coolify.resourceName: "${resource_name}"
      coolify.service.subName: "${sub_name}"
EOF
}

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
$(labels "${ID_SHARED}" "postgres" "nexaduo-shared")
    networks:
      - chat-network
  redis:
    image: redis:7.2.4-alpine
    container_name: scke42coegs5p4h7gnb8kq10
    restart: unless-stopped
    command: ["redis-server", "--requirepass", "${REDIS_PASSWORD}"]
    labels:
$(labels "${ID_SHARED}" "redis" "nexaduo-shared")
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
$(labels "${ID_SHARED}" "cloudflared" "nexaduo-shared")
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
  chatwoot-init:
    image: chatwoot/chatwoot:v4.13.0-ce
    container_name: y61x8ktmxzai3dgfng61kkty
    restart: "no"
    labels:
$(labels "${ID_CHATWOOT}" "chatwoot-init" "nexaduo-chatwoot")
    command: ["bundle", "exec", "rails", "db:prepare"]
    environment:
      RAILS_ENV: production
      POSTGRES_HOST: postgres
      POSTGRES_USERNAME: postgres
      POSTGRES_PASSWORD: '${POSTGRES_PASSWORD}'
      POSTGRES_DATABASE: chatwoot
      REDIS_URL: redis://:${REDIS_PASSWORD}@redis:6379/1
      SECRET_KEY_BASE: '${CHATWOOT_SECRET_KEY_BASE}'
    networks:
      - chat-network
  chatwoot-rails:
    image: chatwoot/chatwoot:v4.13.0-ce
    container_name: kwcwx8psjfytawza93ob3fu2
    restart: unless-stopped
    depends_on:
      chatwoot-init:
        condition: service_completed_successfully
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
$(labels "${ID_CHATWOOT}" "chatwoot-rails" "nexaduo-chatwoot")
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
$(labels "${ID_CHATWOOT}" "chatwoot-sidekiq" "nexaduo-chatwoot")
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
  dify-init:
    image: alpine:3.19
    container_name: fan0icpm1mxpw4wrmaxz6q5o
    restart: "no"
    command: chown -R 1001:1001 /app/api/storage
    labels:
$(labels "${ID_DIFY}" "dify-init" "nexaduo-dify")
    networks:
      - chat-network
  dify-api:
    image: langgenius/dify-api:1.13.3
    container_name: eoxoa4q2v1abcgd0fw0jgz6o
    restart: unless-stopped
    environment:
      MODE: api
      MIGRATION_ENABLED: "true"
      SECRET_KEY: '${DIFY_SECRET_KEY}'
      DB_USERNAME: postgres
      DB_PASSWORD: '${POSTGRES_PASSWORD}'
      DB_HOST: postgres
      DB_DATABASE: dify
      REDIS_HOST: redis
      REDIS_PASSWORD: '${REDIS_PASSWORD}'
      CELERY_BROKER_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
      VECTOR_STORE: pgvector
      PGVECTOR_HOST: postgres
      PGVECTOR_USER: postgres
      PGVECTOR_PASSWORD: '${POSTGRES_PASSWORD}'
      PGVECTOR_DATABASE: dify
      CODE_EXECUTION_ENDPOINT: http://dify-sandbox:8194
      CODE_EXECUTION_API_KEY: '${DIFY_SANDBOX_API_KEY}'
      PLUGIN_DAEMON_URL: http://dify-plugin-daemon:5002
      PLUGIN_DAEMON_KEY: '${DIFY_PLUGIN_DAEMON_KEY}'
      ENABLE_SOCIAL_OAUTH_LOGIN: "true"
      GOOGLE_CLIENT_ID: '${GOOGLE_ID}'
      GOOGLE_CLIENT_SECRET: '${GOOGLE_SECRET}'
    labels:
$(labels "${ID_DIFY}" "dify-api" "nexaduo-dify")
    networks:
      - chat-network
  dify-worker:
    image: langgenius/dify-api:1.13.3
    container_name: vi23kenjpx7wpzqwtb7z8i2d
    restart: unless-stopped
    environment:
      MODE: worker
      SECRET_KEY: '${DIFY_SECRET_KEY}'
      DB_USERNAME: postgres
      DB_PASSWORD: '${POSTGRES_PASSWORD}'
      DB_HOST: postgres
      DB_DATABASE: dify
      REDIS_HOST: redis
      REDIS_PASSWORD: '${REDIS_PASSWORD}'
      CELERY_BROKER_URL: redis://:${REDIS_PASSWORD}@redis:6379/0
    labels:
$(labels "${ID_DIFY}" "dify-worker" "nexaduo-dify")
    networks:
      - chat-network
  dify-web:
    image: langgenius/dify-web:1.13.3
    container_name: zuqklqrp6qgiidmg7l08h74e
    restart: unless-stopped
    environment:
      CONSOLE_API_URL: https://dify.nexaduo.com
      APP_API_URL: https://dify.nexaduo.com
    labels:
$(labels "${ID_DIFY}" "dify-web" "nexaduo-dify")
    networks:
      - chat-network
  dify-sandbox:
    image: langgenius/dify-sandbox:0.2.14
    container_name: s6qj2dpnubh0og4hhzb2cn16
    restart: unless-stopped
    environment:
      API_KEY: '${DIFY_SANDBOX_API_KEY}'
    labels:
$(labels "${ID_DIFY}" "dify-sandbox" "nexaduo-dify")
    networks:
      - chat-network
  dify-plugin-daemon:
    image: langgenius/dify-plugin-daemon:0.5.3-local
    container_name: lmt902sk74qkmtjgxehv81kt
    restart: unless-stopped
    environment:
      SERVER_KEY: '${DIFY_PLUGIN_DAEMON_KEY}'
      DIFY_INNER_API_URL: http://dify-api:5001
      DIFY_INNER_API_KEY: '${DIFY_PLUGIN_DIFY_INNER_API_KEY}'
      DB_HOST: postgres
      DB_USERNAME: postgres
      DB_PASSWORD: '${POSTGRES_PASSWORD}'
      DB_DATABASE: dify_plugin
      REDIS_HOST: redis
      REDIS_PASSWORD: '${REDIS_PASSWORD}'
    labels:
$(labels "${ID_DIFY}" "dify-plugin-daemon" "nexaduo-dify")
    networks:
      - chat-network
  dify-ssrf-proxy:
    image: ubuntu/squid:latest
    container_name: gbmqkh247r2v5d8rw9ks428i
    restart: unless-stopped
    labels:
$(labels "${ID_DIFY}" "dify-ssrf-proxy" "nexaduo-dify")
    networks:
      - chat-network
networks:
  chat-network:
    external: true
    name: nexaduo-network
EOF

# --- NexaDuo Stack ---
cat <<EOF > /tmp/nexaduo.yml
services:
  evolution-api:
    image: atendai/evolution-api:v2.1.1
    container_name: d14aypqa2k5op2ezd3naia76
    restart: unless-stopped
    environment:
      SERVER_TYPE: http
      SERVER_PORT: 8080
      AUTHENTICATION_API_KEY: '${EVOLUTION_API_KEY}'
      DATABASE_PROVIDER: postgresql
      DATABASE_CONNECTION_URI: 'postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/evolution'
      CACHE_REDIS_URI: 'redis://:${REDIS_PASSWORD}@redis:6379/2'
    labels:
$(labels "${ID_NEXADUO}" "evolution-api" "nexaduo-app")
    networks:
      - chat-network
  middleware:
    image: '${MIDDLEWARE_IMAGE}'
    container_name: zhuahbecpn9v39g707gmltku
    restart: unless-stopped
    environment:
      PORT: 4000
      CHATWOOT_BASE_URL: http://chatwoot-rails:3000
      CHATWOOT_API_TOKEN: '${CHATWOOT_API_TOKEN}'
      CHATWOOT_WEBHOOK_TOKEN: '${CHATWOOT_WEBHOOK_TOKEN}'
      DIFY_BASE_URL: http://dify-api:5001/v1
      DATABASE_URL: 'postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/middleware'
      HANDOFF_SHARED_SECRET: '${HANDOFF_SECRET}'
    labels:
$(labels "${ID_NEXADUO}" "middleware" "nexaduo-app")
    networks:
      - chat-network
  self-healing-agent:
    image: '${SELF_HEALING_IMAGE}'
    container_name: fdidkia1e1u4e2m43spd0z51
    restart: unless-stopped
    environment:
      DATABASE_URL: 'postgresql://postgres:${POSTGRES_PASSWORD}@postgres:5432/self_healing'
      LOKI_URL: http://loki:3100
      MIDDLEWARE_URL: http://middleware:4000
      HANDOFF_SHARED_SECRET: '${HANDOFF_SECRET}'
    labels:
$(labels "${ID_NEXADUO}" "self-healing-agent" "nexaduo-app")
    networks:
      - chat-network
  loki:
    image: grafana/loki:3.2.0
    container_name: pbpbpre3x86mrojf60t5e028
    restart: unless-stopped
    user: "0"
    command: -config.file=/etc/loki/loki.yaml
    volumes:
      - /opt/nexaduo/observability/loki/loki.yaml:/etc/loki/loki.yaml:ro
      - kh0g7bovvsmtf9riyocndet3_loki-data:/var/loki
    labels:
$(labels "${ID_NEXADUO}" "loki" "nexaduo-app")
    networks:
      - chat-network
  promtail:
    image: grafana/promtail:3.1.0
    container_name: vcd3a37ebzproldrky55j00z
    restart: unless-stopped
    command: -config.file=/etc/promtail/promtail.yaml
    volumes:
      - /opt/nexaduo/observability/promtail/promtail.yaml:/etc/promtail/promtail.yaml:ro
      - /var/run/docker.sock:/var/run/docker.sock:ro
    labels:
$(labels "${ID_NEXADUO}" "promtail" "nexaduo-app")
    networks:
      - chat-network
  grafana:
    image: grafana/grafana:11.3.0
    container_name: ab9i20xcwqw8xqzu99vh4rkr
    restart: unless-stopped
    environment:
      GF_SECURITY_ADMIN_PASSWORD: '${GRAFANA_PASSWORD}'
      GF_AUTH_GOOGLE_ENABLED: "true"
      GF_AUTH_GOOGLE_CLIENT_ID: '${GOOGLE_ID}'
      GF_AUTH_GOOGLE_CLIENT_SECRET: '${GOOGLE_SECRET}'
      GF_AUTH_GOOGLE_SCOPES: "openid email profile"
      GF_AUTH_GOOGLE_AUTH_URL: "https://accounts.google.com/o/oauth2/v2/auth"
      GF_AUTH_GOOGLE_TOKEN_URL: "https://oauth2.googleapis.com/token"
      GF_AUTH_GOOGLE_ALLOWED_DOMAINS: "nexaduo.com machado.cc"
      GF_SERVER_ROOT_URL: "https://grafana.nexaduo.com"
    volumes:
      - /opt/nexaduo/observability/grafana/provisioning:/etc/grafana/provisioning:ro
      - kh0g7bovvsmtf9riyocndet3_grafana-data:/var/lib/grafana
    labels:
$(labels "${ID_NEXADUO}" "grafana" "nexaduo-app")
    networks:
      - chat-network
  prometheus:
    image: prom/prometheus:v2.55.0
    container_name: zrn1wx3p0yjeorzukg6auwum
    restart: unless-stopped
    command:
      - --config.file=/etc/prometheus/prometheus.yml
      - --storage.tsdb.retention.time=30d
    volumes:
      - /opt/nexaduo/observability/prometheus/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - kh0g7bovvsmtf9riyocndet3_prometheus-data:/prometheus
    labels:
$(labels "${ID_NEXADUO}" "prometheus" "nexaduo-app")
    networks:
      - chat-network
volumes:
  kh0g7bovvsmtf9riyocndet3_loki-data:
    external: true
  kh0g7bovvsmtf9riyocndet3_grafana-data:
    external: true
  kh0g7bovvsmtf9riyocndet3_prometheus-data:
    external: true
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
               sudo bash -c 'cd /data/coolify/services/${uuid} && docker compose up -d --force-recreate --remove-orphans'"
}

deploy_to_vm "${UUID_SHARED}" "/tmp/shared.yml"
deploy_to_vm "${UUID_CHATWOOT}" "/tmp/chatwoot.yml"
deploy_to_vm "${UUID_DIFY}" "/tmp/dify.yml"
deploy_to_vm "${UUID_NEXADUO}" "/tmp/nexaduo.yml"

echo "=== All services redeployed with PERFECT alignment to Coolify DB. ==="
