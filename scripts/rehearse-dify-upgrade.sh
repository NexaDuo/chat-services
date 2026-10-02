#!/usr/bin/env bash
# Rehearse a Dify upgrade on a COPY of production data.
#
# Restores the newest `dify` and `dify_plugin` dumps into a throwaway Postgres,
# copies the Dify storage volumes into throwaway volumes, and boots the Dify
# images pinned in deploy/docker-compose.dify.yml against them on a private
# network. Nothing here writes to the live stack: production volumes are only
# mounted read-only, and the rehearsal containers are never attached to
# nexaduo-network.
#
#   scripts/rehearse-dify-upgrade.sh            # migrate + boot + checks
#   scripts/rehearse-dify-upgrade.sh --invoke   # also send one real chat message
#   scripts/rehearse-dify-upgrade.sh --keep     # leave everything up for inspection
#
# --invoke calls the model provider with the production credentials (one short
# message). It is the only check that proves credentials decrypt and the plugin
# runtime works after the upgrade, so run it before a real cutover.
#
# Requires: Docker/Compose, jq and openssl; the root .env; dumps from
# scripts/backup-host.sh. Logs go to $REHEARSAL_LOG_DIR (mode 700), never to
# stdout: upstream services can print credentials.
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
: "${ENV_FILE:=$ROOT/.env}"
: "${DUMPS_DIR:=$HOME/nexaduo-local/dumps}"
: "${PROD_PROJECT:=chat-services}"
: "${REHEARSAL_LOG_DIR:=$HOME/nexaduo-local/rehearsal}"
invoke=0 keep=0
for arg in "$@"; do
  case "$arg" in
    --invoke) invoke=1 ;;
    --keep) keep=1 ;;
    *) echo "unknown argument: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[rehearsal] $*"; }
die() { echo "[rehearsal] FAIL: $*" >&2; exit 1; }
newest() { ls -1 "$DUMPS_DIR"/$1 2>/dev/null | sort | tail -n 1; }

[[ -f "$ENV_FILE" ]] || die "missing $ENV_FILE"
dify_dump=$(newest 'dify-2*.sql.gz'); plugin_dump=$(newest 'dify_plugin-2*.sql.gz')
storage_tar=$(newest "${PROD_PROJECT}_dify-api-storage-2*.tar.gz")
[[ -n "$dify_dump" && -n "$plugin_dump" && -n "$storage_tar" ]] \
  || die "need dify, dify_plugin dumps and a dify-api-storage archive in $DUMPS_DIR"
for f in "$dify_dump" "$plugin_dump" "$storage_tar"; do gzip -t "$f" || die "corrupt: $f"; done
docker volume inspect "${PROD_PROJECT}_dify-plugin-storage" >/dev/null 2>&1 \
  || die "volume ${PROD_PROJECT}_dify-plugin-storage not found"

proj="dify-rehearsal-$(openssl rand -hex 4)"
work=$(mktemp -d)
mkdir -p -m 700 "$REHEARSAL_LOG_DIR"
logdir="$REHEARSAL_LOG_DIR/$proj"; mkdir -m 700 "$logdir"
export POSTGRES_PASSWORD REDIS_PASSWORD
POSTGRES_PASSWORD="$(openssl rand -hex 24)"; REDIS_PASSWORD="$(openssl rand -hex 24)"

helper=$(sed -n 's/^: "\${BACKUP_HELPER_IMAGE:=\([^}]*\)}".*/\1/p' "$ROOT/scripts/backup-host.sh")
shared=$(docker compose --env-file /dev/null -f "$ROOT/deploy/docker-compose.shared.yml" \
  config --format json 2>/dev/null)
pg_image=$(jq -er '.services.postgres.image' <<<"$shared")
redis_image=$(jq -er '.services.redis.image' <<<"$shared")

# Labels are reset so the live Traefik and autoheal ignore these containers
# (a duplicate router for the Dify hosts would hijack production traffic), and
# the log driver is off so Alloy ships nothing to Loki for the self-healing
# agent to analyse. `compose up` is attached instead and tee'd to $logdir.
services=(dify-api dify-worker dify-web dify-sandbox dify-plugin-daemon dify-ssrf-proxy)
{
  echo "services:"
  for svc in "${services[@]}" dify-init; do
    printf '  %s:\n    labels: !reset []\n    ports: !reset []\n    restart: "no"\n    logging: !override\n      driver: none\n' "$svc"
  done
  cat <<YAML
volumes:
  dify-api-storage:
    external: true
    name: ${proj}_dify-api-storage
  dify-plugin-storage:
    external: true
    name: ${proj}_dify-plugin-storage
networks:
  chat-network:
    external: true
    name: ${proj}
YAML
} > "$work/override.yml"
dc() {
  (cd "$ROOT" && docker compose --env-file "$ENV_FILE" -p "$proj" \
    -f deploy/docker-compose.dify.yml -f "$work/override.yml" "$@")
}

cleanup() {
  local status=$?
  trap - EXIT
  if (( keep )); then
    log "kept: project $proj (network, volumes, containers); logs in $logdir"
    log "remove with: docker ps -aq --filter name=$proj | xargs -r docker rm -fv; docker volume ls -q | grep ^$proj | xargs -r docker volume rm; docker network rm $proj"
  else
    dc down --timeout 5 >/dev/null 2>&1 || true
    docker rm -fv "$proj-postgres" "$proj-redis" >/dev/null 2>&1 || true
    docker volume rm "${proj}_dify-api-storage" "${proj}_dify-plugin-storage" "${proj}_pg" >/dev/null 2>&1 || true
    docker network rm "$proj" >/dev/null 2>&1 || true
  fi
  rm -rf "$work"
  (( status == 0 )) || log "failed; service logs (may contain secrets) are in $logdir"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

psql_db() { docker exec -i "$proj-postgres" psql -v ON_ERROR_STOP=1 -U postgres -d "$1" -At "${@:2}"; }
wait_for() { # description, seconds, command...
  local what=$1 limit=$2 start=$SECONDS; shift 2
  until "$@" >/dev/null 2>&1; do
    (( SECONDS - start < limit )) || die "$what not ready after ${limit}s"
    sleep 2
  done
}

log "project $proj; dumps: $(basename "$dify_dump"), $(basename "$plugin_dump"); storage: $(basename "$storage_tar")"
docker network create "$proj" >/dev/null
for v in dify-api-storage dify-plugin-storage pg; do docker volume create "${proj}_$v" >/dev/null; done
docker run --rm -i -v "${proj}_dify-api-storage:/dst" "$helper" tar xzf - -C /dst < "$storage_tar"
# The plugin volume is not in the default backup set: copy it from the live
# volume, mounted read-only.
docker run --rm -v "${PROD_PROJECT}_dify-plugin-storage:/src:ro" \
  -v "${proj}_dify-plugin-storage:/dst" "$helper" cp -a /src/. /dst/

docker run -d --name "$proj-postgres" --network "$proj" --network-alias postgres \
  --log-driver none -e POSTGRES_PASSWORD -v "${proj}_pg:/var/lib/postgresql/data" "$pg_image" >/dev/null
docker run -d --name "$proj-redis" --network "$proj" --network-alias redis \
  --log-driver none -e REDIS_PASSWORD "$redis_image" \
  sh -c 'exec redis-server --requirepass "$REDIS_PASSWORD"' >/dev/null
# TCP, not the socket: the image's init phase runs a socket-only server first.
wait_for Postgres 60 docker exec "$proj-postgres" pg_isready -q -h 127.0.0.1 -U postgres
for db in dify dify_plugin; do
  docker exec "$proj-postgres" psql -U postgres -Atc "create database $db" >/dev/null
done
gzip -dc "$dify_dump" | psql_db dify >/dev/null 2>"$logdir/restore-dify.err" || die "dify restore failed"
gzip -dc "$plugin_dump" | psql_db dify_plugin >/dev/null 2>"$logdir/restore-plugin.err" || die "dify_plugin restore failed"

# Row counts that a version upgrade must not change. Provider tables are
# excluded: the legacy model type migration is allowed to merge rows there.
tables=(tenants accounts apps app_model_configs api_tokens datasets documents document_segments
        conversations messages workflows installed_apps)
snapshot() {
  local t
  for t in "${tables[@]}"; do
    printf '%s=%s\n' "$t" "$(psql_db dify -c "select count(*) from \"$t\"")"
  done
  printf 'plugins=%s\n' "$(psql_db dify_plugin -c 'select count(*) from plugins')"
  printf 'plugin_installations=%s\n' "$(psql_db dify_plugin -c 'select count(*) from plugin_installations')"
}
before_rev=$(psql_db dify -c 'select version_num from alembic_version')
snapshot > "$work/before.txt"
legacy="select count(*) from provider_models where model_type in ('text-generation','embeddings','reranking')"
log "before: alembic $before_rev, legacy model types: $(psql_db dify -c "$legacy")"

log "migrating (MODE=migration, same command as the cutover)"
start=$SECONDS
dc run --rm --no-deps -e MODE=migration -e MIGRATION_ENABLED=true dify-api \
  > "$logdir/migration.log" 2>&1 || die "migration failed (see $logdir/migration.log)"
after_rev=$(psql_db dify -c 'select version_num from alembic_version')
log "migrated in $((SECONDS - start))s: alembic $before_rev -> $after_rev"
[[ "$after_rev" != "$before_rev" ]] || log "note: alembic revision unchanged (same schema version)"

dc up --no-deps dify-ssrf-proxy dify-sandbox dify-plugin-daemon > "$logdir/support.log" 2>&1 &
dc up --no-deps dify-api dify-worker dify-web > "$logdir/app.log" 2>&1 &
api() { dc exec -T dify-api curl -fsS --max-time 8 "$@"; }
wait_for "dify-api /health" 300 api http://127.0.0.1:5001/health
wait_for "plugin daemon" 120 dc exec -T dify-api curl -fsS --max-time 5 http://dify-plugin-daemon:5002/health/check
wait_for "dify-worker" 240 dc exec -T dify-worker celery -A app.celery inspect ping --timeout 5
wait_for "dify-web" 120 dc exec -T dify-web sh -c 'wget -qO- -T 5 http://$HOSTNAME:3000/ >/dev/null'
log "api, worker, web and plugin daemon are up"

# A second boot must find nothing to migrate.
[[ "$(psql_db dify -c 'select version_num from alembic_version')" == "$after_rev" ]] || die "revision moved on boot"
snapshot > "$work/after.txt"
diff -u "$work/before.txt" "$work/after.txt" > "$logdir/counts.diff" || die "row counts changed (see $logdir/counts.diff)"
[[ "$(psql_db dify -c "$legacy")" == 0 ]] || die "legacy model types remain after migration"
log "row counts preserved: $(tr '\n' ' ' < "$work/after.txt")"
[[ "$(api http://127.0.0.1:5001/console/api/setup | jq -r .step)" == finished ]] || die "setup state lost"

# The plugin daemon calls back into the API with DIFY_INNER_API_KEY; the API
# must expect the same key (compared by hash, never printed), and the worker
# must see the same vector store as the API.
api_key=$(dc exec -T dify-api python -c 'import hashlib; from configs import dify_config as c; print(hashlib.sha256(c.INNER_API_KEY_FOR_PLUGIN.encode()).hexdigest())' 2>/dev/null | tail -n 1)
daemon_key=$(dc exec -T dify-plugin-daemon sh -c 'printf %s "$DIFY_INNER_API_KEY" | sha256sum' | cut -d' ' -f1)
[[ -n "$api_key" && "$api_key" == "$daemon_key" ]] || die "inner API key differs between dify-api and the plugin daemon"
for svc in dify-api dify-worker; do
  [[ "$(dc exec -T "$svc" sh -c 'echo "$VECTOR_STORE"')" == pgvector ]] || die "$svc: VECTOR_STORE is not pgvector"
done
log "config: inner API key matches the plugin daemon; api and worker use pgvector"

# Console login, then read back apps, model providers and plugins through the
# API the web UI uses. The password is reset in the COPY only, so the check
# does not depend on the operator password and never touches the live account.
REHEARSAL_EMAIL=$(psql_db dify -c 'select email from accounts order by created_at limit 1')
REHEARSAL_PASSWORD="Rh$(openssl rand -hex 12)9"
dc exec -T dify-api flask reset-password --email "$REHEARSAL_EMAIL" \
  --new-password "$REHEARSAL_PASSWORD" --password-confirm "$REHEARSAL_PASSWORD" \
  > "$logdir/reset-password.log" 2>&1 || die "password reset in the copy failed"
REHEARSAL_EMAIL=$REHEARSAL_EMAIL REHEARSAL_PASSWORD=$REHEARSAL_PASSWORD \
EXPECT_APPS=$(sed -n 's/^apps=//p' "$work/after.txt") \
EXPECT_PLUGINS=$(sed -n 's/^plugin_installations=//p' "$work/after.txt") \
  dc exec -T -e REHEARSAL_EMAIL -e REHEARSAL_PASSWORD -e EXPECT_APPS -e EXPECT_PLUGINS dify-api python - \
  > "$logdir/console.log" 2>&1 <<'PY' || die "console checks failed (see $logdir/console.log)"
import base64, os, httpx
base = 'http://127.0.0.1:5001/console/api'
c = httpx.Client(timeout=60)
password = base64.b64encode(os.environ['REHEARSAL_PASSWORD'].encode()).decode()
r = c.post(f'{base}/login', json={'email': os.environ['REHEARSAL_EMAIL'], 'password': password, 'remember_me': False})
assert r.status_code == 200, f'login {r.status_code}'
# Session cookies are Secure, so a plain-HTTP client will not replay them:
# send them by hand, with the CSRF token the console expects.
jar = dict(h.split(';', 1)[0].split('=', 1) for h in r.headers.get_list('set-cookie'))
assert {'access_token', 'csrf_token'} <= set(jar), sorted(jar)
headers = {'Cookie': '; '.join(f'{k}={v}' for k, v in jar.items()), 'X-CSRF-Token': jar['csrf_token']}
def get(path):
    r = c.get(f'{base}{path}', headers=headers)
    assert r.status_code == 200, f'{path} {r.status_code}'
    return r.json()
apps = get('/apps?page=1&limit=100')
assert apps['total'] == int(os.environ['EXPECT_APPS']), ('apps', apps['total'])
providers = [p for p in get('/workspaces/current/model-providers')['data']
             if (p.get('custom_configuration') or {}).get('status') == 'active']
assert providers, 'no active model provider'
models = get('/workspaces/current/models/model-types/llm')['data']
assert any(m.get('models') for m in models), 'no llm model listed'
plugins = get('/workspaces/current/plugin/list?page=1&page_size=100')
assert len(plugins['plugins']) == int(os.environ['EXPECT_PLUGINS']), ('plugins', len(plugins['plugins']))
print(f'apps={apps["total"]} active_providers={len(providers)} llm_providers={len(models)} plugins={len(plugins["plugins"])}')
PY
log "console: $(tail -n 1 "$logdir/console.log")"

if (( invoke )); then
  # One message (or workflow run) per app that has a service API token. Tokens are read from the
  # rehearsal copy and passed through the environment, never printed.
  psql_db dify -F ' ' -c "select distinct on (a.id) a.mode, t.token from apps a join api_tokens t on t.app_id = a.id and t.type = 'app' order by a.id" \
    > "$work/tokens.txt"
  [[ -s "$work/tokens.txt" ]] || die "--invoke: no app API token in the copy"
  n=0
  while read -r mode token; do
    n=$((n + 1))
    APP_MODE=$mode APP_TOKEN=$token dc exec -T -e APP_MODE -e APP_TOKEN dify-api python - \
      > "$logdir/invoke-$n.log" 2>&1 <<'PY' || die "--invoke failed for app $n (see $logdir/invoke-$n.log)"
import json, os, httpx
mode, headers = os.environ['APP_MODE'], {'Authorization': 'Bearer ' + os.environ['APP_TOKEN']}
base = 'http://127.0.0.1:5001/v1'
# Fill the app's declared inputs with synthetic values of the right kind.
inputs = {}
form = httpx.get(base + '/parameters', headers=headers, timeout=30)
assert form.status_code == 200, f'/parameters {form.status_code}'
for field in form.json().get('user_input_form', []):
    kind, spec = next(iter(field.items()))
    if kind == 'number': value = 1
    elif kind == 'select': value = (spec.get('options') or [''])[0]
    elif kind in ('text-input', 'paragraph'): value = 'upgrade rehearsal'
    else: continue
    inputs[spec['variable']] = value
if mode == 'workflow':
    body = {'inputs': inputs, 'response_mode': 'blocking', 'user': 'upgrade-rehearsal'}
    r = httpx.post(base + '/workflows/run', json=body, headers=headers, timeout=180)
    assert r.status_code == 200, f'/workflows/run {r.status_code}'
    data = r.json()['data']
    assert data['status'] == 'succeeded', data['status']
    print(f'mode=workflow status={data["status"]} outputs={sorted(data.get("outputs") or {})}')
    raise SystemExit(0)
path = '/completion-messages' if mode == 'completion' else '/chat-messages'
body = {'inputs': inputs, 'query': 'ping', 'response_mode': 'streaming', 'user': 'upgrade-rehearsal'}
answer, events = '', set()
with httpx.stream('POST', base + path, json=body, headers=headers, timeout=180) as r:
    assert r.status_code == 200, f'{path} {r.status_code}'
    for line in r.iter_lines():
        if not line.startswith('data: '): continue
        event = json.loads(line[6:])
        events.add(event.get('event'))
        assert event.get('event') != 'error', 'error event: ' + str(event.get('code'))
        answer += event.get('answer') or ''
assert 'message_end' in events, sorted(e for e in events if e)
assert answer.strip(), 'empty answer'
print(f'mode={mode} answer_chars={len(answer)} events={",".join(sorted(e for e in events if e))}')
PY
    log "invoke app $n: $(tail -n 1 "$logdir/invoke-$n.log")"
  done < "$work/tokens.txt"
fi

for svc in dify-api dify-worker dify-plugin-daemon; do
  c=$(dc ps -q "$svc")
  log "$svc: $(docker inspect -f 'restarts={{.RestartCount}} oom={{.State.OOMKilled}}' "$c") mem=$(docker stats --no-stream --format '{{.MemUsage}}' "$c")"
done
log "PASS in ${SECONDS}s"
