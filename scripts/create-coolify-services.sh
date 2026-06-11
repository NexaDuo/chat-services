#!/usr/bin/env bash
#
# create-coolify-services.sh <env>
#
# Idempotently ensures the Coolify project and the four compose-based services
# (shared / chatwoot / dify / nexaduo) exist for an environment, then prints
# their UUIDs as a tfvars-ready HCL map on stdout.
#
# Why this exists: the tenant Terraform layer manages services as DATA SOURCES
# keyed by `coolify_service_uuids` (the Coolify provider cannot UPDATE a service
# without panicking — see AGENTS.md "AVOID Coolify TF Provider for Service
# Stacks"). So the services must pre-exist. This script is the reproducible,
# code-driven way to stand up (or rebuild) an environment from scratch: it
# creates the services via the Coolify API and emits the UUID map to feed into
# `terraform_tfvars_<env>`. The tenant pipeline then manages their env vars and
# deploys them.
#
# Idempotent: services are matched by name and reused if present, so re-runs are
# no-ops and running it against an already-provisioned env (e.g. production)
# changes nothing.
#
# Connection details come from per-env Secret Manager secrets:
#   coolify_url_<env>, coolify_api_token_<env>, coolify_destination_uuid_<env>
#
set -euo pipefail

ENV="${1:?usage: create-coolify-services.sh <env> (e.g. staging|production)}"
PROJECT_ID="${GCP_PROJECT_ID:-nexaduo-492818}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Production services have no suffix; every other env is "-<env>" (matches the
# old `local.service_suffix` and the existing nexaduo-<stack>[-<env>] names).
SUFFIX=""
[ "$ENV" != "production" ] && SUFFIX="-${ENV}"

URL="$(gcloud secrets versions access latest --secret="coolify_url_${ENV}" --project="$PROJECT_ID")"
TOKEN="$(gcloud secrets versions access latest --secret="coolify_api_token_${ENV}" --project="$PROJECT_ID")"
DEST="$(gcloud secrets versions access latest --secret="coolify_destination_uuid_${ENV}" --project="$PROJECT_ID")"

python3 - "$URL" "$TOKEN" "$DEST" "$ENV" "$SUFFIX" "$ROOT" <<'PY'
import json, sys, base64, urllib.request, urllib.error

URL, TOKEN, DEST, ENV, SUFFIX, ROOT = sys.argv[1:7]
HEADERS = {"Authorization": "Bearer " + TOKEN, "Accept": "application/json"}

def api(method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    headers = dict(HEADERS)
    if data:
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(URL + path, data=data, headers=headers, method=method)
    try:
        r = urllib.request.urlopen(req, timeout=60)
        text = r.read().decode()
        return r.status, (json.loads(text) if text.strip() else None)
    except urllib.error.HTTPError as e:
        return e.code, e.read().decode()

# Server: this stack runs on a single Coolify server (localhost).
st, servers = api("GET", "/servers")
if st != 200 or not servers:
    sys.stderr.write("FATAL: could not list servers: %s %s\n" % (st, servers)); sys.exit(1)
server_uuid = servers[0]["uuid"]

# Project: ensure "NexaDuo Chat Services (<env>)" exists.
proj_name = "NexaDuo Chat Services (%s)" % ENV
st, projects = api("GET", "/projects")
proj = next((p for p in (projects or []) if p.get("name") == proj_name), None)
if proj:
    project_uuid = proj["uuid"]
    sys.stderr.write("reuse project %s -> %s\n" % (proj_name, project_uuid))
else:
    st, res = api("POST", "/projects", {"name": proj_name})
    if st not in (200, 201) or not isinstance(res, dict):
        sys.stderr.write("FATAL: create project failed: %s %s\n" % (st, res)); sys.exit(1)
    project_uuid = res["uuid"]
    sys.stderr.write("created project %s -> %s\n" % (proj_name, project_uuid))

# (tfvars key, service-name component, compose file). The "nexaduo" stack is
# named "nexaduo-app" — its name component differs from its map key.
STACKS = [
    ("shared",   "shared",   "docker-compose.shared.yml"),
    ("chatwoot", "chatwoot", "docker-compose.chatwoot.yml"),
    ("dify",     "dify",     "docker-compose.dify.yml"),
    ("nexaduo",  "app",      "docker-compose.nexaduo.yml"),
]

st, allsvc = api("GET", "/services")
by_name = {s.get("name"): s["uuid"] for s in (allsvc or [])}

out = {}
for stack, name_part, compose_file in STACKS:
    name = "nexaduo-%s%s" % (name_part, SUFFIX)
    if name in by_name:
        out[stack] = by_name[name]
        sys.stderr.write("reuse service %s -> %s\n" % (name, out[stack]))
        continue
    with open("%s/deploy/%s" % (ROOT, compose_file)) as fh:
        compose_b64 = base64.b64encode(fh.read().encode()).decode()
    st, res = api("POST", "/services", {
        "name": name,
        "server_uuid": server_uuid,
        "project_uuid": project_uuid,
        "environment_name": "production",
        "destination_uuid": DEST,
        "docker_compose_raw": compose_b64,
        "instant_deploy": False,
    })
    if st not in (200, 201) or not isinstance(res, dict) or "uuid" not in res:
        sys.stderr.write("FATAL: create service %s failed: %s %s\n" % (name, st, res)); sys.exit(1)
    out[stack] = res["uuid"]
    sys.stderr.write("created service %s -> %s\n" % (name, out[stack]))

# tfvars-ready HCL on stdout.
print('project_uuid = "%s"' % project_uuid)
print('coolify_service_uuids = {')
for k in ("shared", "chatwoot", "dify", "nexaduo"):
    print('  %s = "%s"' % (k, out[k]))
print('}')
PY
