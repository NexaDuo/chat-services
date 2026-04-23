#!/usr/bin/env bash
# scripts/clean-service-envs.sh
#
# Workaround for a known quirk of the Coolify provider:
# when a `coolify_service` is created from a compose file, Coolify parses the
# compose and auto-creates placeholder env vars for every `${VAR}` interpolation.
# The subsequent `coolify_service_envs` POST then fails with:
#
#     409 Conflict
#     "Environment variable already exists. Use PATCH request to update it."
#
# This script deletes every env var currently attached to the given services,
# leaving Terraform free to POST them cleanly on the next apply.
#
# Usage:
#   ./scripts/clean-service-envs.sh                 # reads UUIDs from tenant state
#   ./scripts/clean-service-envs.sh <uuid> [<uuid>] # explicit UUIDs

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
TENANT_DIR="${PROJECT_ROOT}/infrastructure/terraform/envs/production/tenant"
PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"

COOLIFY_URL="$(gcloud secrets versions access latest --secret=coolify_url --project="${PROJECT_ID}")"
COOLIFY_TOKEN="$(gcloud secrets versions access latest --secret=coolify_api_token --project="${PROJECT_ID}")"
BASE="${COOLIFY_URL%/api/v1}"

if [[ $# -gt 0 ]]; then
  UUIDS=("$@")
else
  mapfile -t UUIDS < <(
    cd "${TENANT_DIR}"
    for svc in shared chatwoot dify nexaduo; do
      terraform state show "coolify_service.${svc}" 2>/dev/null \
        | awk '/^    uuid /{gsub(/"/,""); print $3; exit}'
    done
  )
fi

if [[ ${#UUIDS[@]} -eq 0 ]]; then
  echo "No services in tenant state; nothing to clean."
  exit 0
fi

export COOLIFY_URL="${BASE}" COOLIFY_TOKEN
python3 - "${UUIDS[@]}" <<'PYEOF'
import json, os, sys, urllib.request

base = os.environ["COOLIFY_URL"]
token = os.environ["COOLIFY_TOKEN"]
headers = {"Authorization": f"Bearer {token}"}

for svc in sys.argv[1:]:
    try:
        envs = json.loads(urllib.request.urlopen(
            urllib.request.Request(f"{base}/api/v1/services/{svc}/envs", headers=headers)
        ).read())
    except Exception as ex:
        print(f"{svc}: list failed ({ex})")
        continue
    print(f"{svc}: {len(envs)} env(s)")
    for e in envs:
        req = urllib.request.Request(
            f"{base}/api/v1/services/{svc}/envs/{e['uuid']}",
            method="DELETE", headers=headers,
        )
        try:
            resp = urllib.request.urlopen(req)
            print(f"  DEL {e['key']}: {resp.status}")
        except Exception as ex:
            print(f"  DEL {e['key']}: ERR {ex}")
PYEOF
