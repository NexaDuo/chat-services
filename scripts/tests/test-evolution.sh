#!/usr/bin/env bash
# Synthetic Prisma upgrade only; no host .env, existing volumes or live network.
# Requires Docker/Compose, jq, Python 3, openssl and GNU timeout.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export EVOLUTION_API_KEY="$(openssl rand -hex 24)"
export POSTGRES_PASSWORD="$(openssl rand -hex 24)"
export REDIS_PASSWORD="$(openssl rand -hex 24)"
export MIDDLEWARE_IMAGE=synthetic/middleware SELF_HEALING_IMAGE=synthetic/self-healing
export NEXADUO_CONF_PATH="$ROOT"
export EVOLUTION_TEST_CONFIG="$(docker compose --env-file /dev/null -p w6-config \
  -f "$ROOT/deploy/docker-compose.shared.yml" -f "$ROOT/deploy/docker-compose.nexaduo.yml" \
  config --format json 2>/dev/null | jq -c '.services | {"evolution-api": .["evolution-api"], postgres, redis}')"
export EVOLUTION_OLD_IMAGE='evoapicloud/evolution-api:v2.1.1@sha256:c7d72f0795341498f1d61751b8f35ab48037683ee50450a445b0079c1509c25e'
image=$(jq -er '.["evolution-api"].image' <<<"$EVOLUTION_TEST_CONFIG")
[[ $image =~ ^evoapicloud/evolution-api:v2\.3\.[0-9]+@sha256:[a-f0-9]{64}$ ]]
for img in "$EVOLUTION_OLD_IMAGE" "$image" $(jq -r '.postgres.image, .redis.image' <<<"$EVOLUTION_TEST_CONFIG"); do
  docker pull "$img" >/dev/null
done
export EVOLUTION_TEST_NAME="w6-evolution-$(cat /proc/sys/kernel/random/uuid)"
cleanup() {
  local status=$?
  trap - EXIT
  # Never dump logs: upstream startup/API responses can contain credentials.
  timeout 8s docker rm -fv "$EVOLUTION_TEST_NAME-api" "$EVOLUTION_TEST_NAME-pg" "$EVOLUTION_TEST_NAME-redis" >/dev/null 2>&1 || true
  timeout 5s docker volume rm "$EVOLUTION_TEST_NAME-instances" "$EVOLUTION_TEST_NAME-pg" "$EVOLUTION_TEST_NAME-redis" >/dev/null 2>&1 || true
  timeout 5s docker network rm "$EVOLUTION_TEST_NAME" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# Pulls precede 210s + 2s kill grace + 18s cleanup (<240s).
timeout --signal=TERM --kill-after=2s 210s python3 - <<'PY'
import json, os, subprocess, time
cfg = json.loads(os.environ['EVOLUTION_TEST_CONFIG'])
evo = cfg['evolution-api']
name = os.environ['EVOLUTION_TEST_NAME']
api, pg, redis = (name + suffix for suffix in ('-api', '-pg', '-redis'))
started = time.monotonic()

def docker(*args):
    try:
        return subprocess.check_output(['docker', *args], text=True, stderr=subprocess.DEVNULL, timeout=20).strip()
    except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as e:
        raise RuntimeError(f'docker {args[0]} failed: {type(e).__name__}') from None

def sql(query):
    return docker('exec', pg, 'psql', '-U', 'postgres', '-d', 'evolution', '-Atc', query)

def wait(check, description, seconds=80):
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        try:
            if check(): return
        except (RuntimeError, ValueError): pass
        time.sleep(.5)
    raise AssertionError(description + ' timed out')

# HTTP stays inside the disposable container; no host ports or Meta connection.
request_js = '''
const http = require('http');
const [path, auth, body] = process.argv.slice(1);
const headers = {'content-type': 'application/json'};
if (auth === 'yes') headers.apikey = process.env.AUTHENTICATION_API_KEY;
const req = http.request({host:'127.0.0.1', port:process.env.SERVER_PORT,
 path, method:body ? 'POST' : 'GET', headers}, res => {
 let data = ''; res.on('data', c => data += c);
 res.on('end', () => console.log(JSON.stringify({status:res.statusCode, body:data})));
});
req.setTimeout(6000, () => req.destroy());
req.on('error', () => process.exit(1));
req.end(body);
'''
def request(path, body=None, auth=True, status=200):
    result = json.loads(docker('exec', api, 'node', '-e', request_js, path,
                              'yes' if auth else 'no', json.dumps(body) if body else ''))
    assert result['status'] == status, f'{path}: expected {status}, got {result["status"]}'
    return json.loads(result['body'])

def ready(version):
    try: return request('/')['version'] == version
    except (AssertionError, RuntimeError, ValueError): return False

def start(image, version):
    args = ['run', '-d', '--name', api, '--network', name, '--restart=no',
            '--memory', str(evo['mem_limit'])]
    for key, value in evo['environment'].items(): args += ['-e', f'{key}={value}']
    volumes = evo['volumes']
    assert len(volumes) == 1 and volumes[0]['target'] == '/evolution/instances'
    args += ['-v', name + '-instances:' + volumes[0]['target']]
    if evo.get('user'): args += ['--user', evo['user']]
    assert not evo.get('entrypoint') and not evo.get('command')
    docker(*args, image)
    wait(lambda: ready(version), version + ' readiness')

settings = dict(rejectCall=True, msgCall='synthetic W6', groupsIgnore=True,
                alwaysOnline=False, readMessages=False, readStatus=False, syncFullHistory=False)
webhook = dict(enabled=False, url='http://127.0.0.1:9/synthetic',
               byEvents=True, base64=True, events=[])

def verify(version):
    assert ready(version)
    request('/instance/fetchInstances', auth=False, status=401)
    instances = request('/instance/fetchInstances')
    # 2.1.1 wraps entries in instance; 2.3.7 returns the Prisma shape directly.
    entries = [item.get('instance', item) for item in instances]
    assert len(entries) == 1
    assert entries[0].get('name', entries[0].get('instanceName')) == 'w6-synthetic'
    saved = request('/settings/find/w6-synthetic')
    assert all(saved.get(k) == v for k, v in settings.items()), 'Settings changed'
    saved = request('/webhook/find/w6-synthetic')
    assert all(saved.get({'byEvents': 'webhookByEvents', 'base64': 'webhookBase64'}.get(k, k)) == v
               for k, v in webhook.items()), 'Webhook changed'
    assert sql('SELECT count(*) FROM "_prisma_migrations" WHERE finished_at IS NULL OR rolled_back_at IS NOT NULL') == '0'
    # `compose config` keeps the $$ escape; the engine receives a single $.
    health = [part.replace('$$', '$') for part in evo['healthcheck']['test']]
    # The probe must not carry the key itself nor depend on the egress-bound "/".
    assert health[0] == 'CMD-SHELL' and '$AUTHENTICATION_API_KEY' in health[1]
    assert '/instance/fetchInstances' in health[1]
    docker('exec', api, 'sh', '-c', health[1])
    # Same probe with a wrong key must fail: it really exercises the guard.
    try:
        docker('exec', '-e', 'AUTHENTICATION_API_KEY=wrong', api, 'sh', '-c', health[1])
    except RuntimeError: pass
    else: raise AssertionError('Healthcheck passed with a wrong key')

# Only aliases postgres/redis on our new private network resolve Compose URIs.
docker('network', 'create', name)
for suffix in ('-instances', '-pg', '-redis'): docker('volume', 'create', name + suffix)
docker('run', '-d', '--name', pg, '--network', name, '--network-alias', 'postgres',
       '-e', 'POSTGRES_PASSWORD=' + os.environ['POSTGRES_PASSWORD'], '-e', 'POSTGRES_DB=evolution',
       cfg['postgres']['image'])
docker('run', '-d', '--name', redis, '--network', name, '--network-alias', 'redis',
       '-v', name + '-redis:/data', cfg['redis']['image'], *cfg['redis']['command'])
wait(lambda: sql('SELECT 1') == '1', 'Postgres', 25)
start(os.environ['EVOLUTION_OLD_IMAGE'], '2.1.1')
assert sql('SELECT count(*) FROM "_prisma_migrations"') == '42'
request('/instance/create', dict(instanceName='w6-synthetic', integration='EVOLUTION', qrcode=False), status=201)
request('/settings/set/w6-synthetic', settings, status=201)
request('/webhook/set/w6-synthetic', dict(webhook=webhook), status=201)
verify('2.1.1')
old_id = sql('SELECT id FROM "Instance"')
docker('stop', '-t', '5', api)
docker('rm', api)
# Guard against both starts silently using the same image.
new = evo['image'].split(':v', 1)[1].split('@', 1)[0]
start(evo['image'], new)
verify(new)
assert sql('SELECT id FROM "Instance"') == old_id
count = int(sql('SELECT count(*) FROM "_prisma_migrations"'))
assert count > 42
snapshot = sql('SELECT id, checksum, finished_at FROM "_prisma_migrations" ORDER BY id')
docker('restart', '-t', '5', api)
wait(lambda: ready(new), 'Restart readiness')
verify(new)
assert sql('SELECT id, checksum, finished_at FROM "_prisma_migrations" ORDER BY id') == snapshot
assert sql('SELECT id FROM "Instance"') == old_id
print(f'PASS: Evolution 42 → {count} migrations, instance/settings/webhook, auth, healthcheck, idempotent restart ({time.monotonic()-started:.1f}s)')
PY
