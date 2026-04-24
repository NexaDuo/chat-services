#!/usr/bin/env bash
# validation/compose-health.sh
# Validação técnica da stack via Docker Compose (sem dependência de dados/onboarding)

set -euo pipefail

step() { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit 1; }

# 1. Verificar se os containers principais estão UP
step "Checking container status"
services=(
  nexaduo-postgres
  nexaduo-redis
  nexaduo-chatwoot-rails
  nexaduo-dify-api
  nexaduo-middleware
  nexaduo-grafana
)

for service in "${services[@]}"; do
  status=$(docker inspect -f '{{.State.Status}}' "$service" 2>/dev/null || echo "missing")
  if [[ "$status" != "running" ]]; then
    fail "Service $service is not running (status: $status)"
  fi
  echo "  - $service is $status"
done

# 2. Verificar Healthchecks do Docker
step "Checking Docker healthchecks"
healthy_required=(
  nexaduo-postgres
  nexaduo-redis
)

for service in "${healthy_required[@]}"; do
  health=$(docker inspect -f '{{.State.Health.Status}}' "$service" 2>/dev/null || echo "no-healthcheck")
  if [[ "$health" != "healthy" ]]; then
    fail "Service $service is not healthy (health: $health)"
  fi
  echo "  - $service is $health"
done

# 3. Probes de rede básicos (Portas/HTTP)
step "Probing HTTP endpoints"
declare -a PROBES=(
  "Chatwoot|http://localhost:3000/|200,301,302"
  "Dify|http://localhost:3001/install|200"
  "Middleware|http://localhost:4000/health|200"
  "Grafana|http://localhost:3002/login|200"
)

for probe in "${PROBES[@]}"; do
  IFS="|" read -r name url codes <<< "$probe"
  code=$(curl -s -o /dev/null -w '%{http_code}' "$url" || true)
  if ! echo ",$codes," | grep -q ",$code,"; then
    fail "$name at $url returned $code (expected one of $codes)"
  fi
  echo "  - $name is alive ($code)"
done

echo "OK: Compose infrastructure is technically sound."
