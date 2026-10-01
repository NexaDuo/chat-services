#!/usr/bin/env bash
# Synthetic broker migration only. Requires Docker/Compose, jq, Python 3, openssl,
# GNU timeout. No host .env, production network, or existing volume is used.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export REDIS_PASSWORD="$(openssl rand -hex 24)"
config=$(docker compose --env-file /dev/null -p w5a-config \
  -f "$ROOT/deploy/docker-compose.shared.yml" config --format json 2>/dev/null)
export REDIS_TEST_CONFIG="$(jq -c '.services.redis' <<<"$config")"
export REDIS_OLD_IMAGE='redis:7.2.4-alpine@sha256:c8bb255c3559b3e458766db810aa7b3c7af1235b204cfdb304e79ff388fe1a5a'
image=$(jq -er '.image' <<<"$REDIS_TEST_CONFIG")
# Constrain major.minor, permit patch updates only, and require an index digest.
[[ $image =~ ^redis:7\.2\.[0-9]+-alpine@sha256:[a-f0-9]{64}$ ]]
docker pull "$REDIS_OLD_IMAGE" >/dev/null
docker pull "$image" >/dev/null
export REDIS_TEST_NAME="w5a-redis-$(cat /proc/sys/kernel/random/uuid)"
cleanup() {
  local status=$?
  trap - EXIT
  timeout 5s docker rm -f "$REDIS_TEST_NAME" >/dev/null 2>&1 || true
  timeout 5s docker volume rm "$REDIS_TEST_NAME" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# 105s + 2s kill grace + 10s cleanup <120s; pulls are outside the budget.
timeout --signal=TERM --kill-after=2s 105s python3 - <<'PY'
import json, os, socket, subprocess, time
cfg = json.loads(os.environ['REDIS_TEST_CONFIG'])
name = os.environ['REDIS_TEST_NAME']
password = os.environ['REDIS_PASSWORD']
started = time.monotonic()
def docker(*args):
    return subprocess.check_output(['docker', *args], text=True, timeout=15).strip()

class Client:
    """One client instance across the cutover; reconnect after socket loss."""
    def connect(self, port):
        self.sock = socket.create_connection(('127.0.0.1', port), timeout=3)
        self.file = self.sock.makefile('rb')
    def close(self):
        self.file.close()
        self.sock.close()
    def read(self):
        line = self.file.readline()
        if not line:
            raise ConnectionError('Redis disconnected')
        kind, body = line[:1], line[1:-2]
        if kind == b'-':
            raise RuntimeError(body.decode())
        if kind == b'+': return body.decode()
        if kind == b':': return int(body)
        if kind == b'$':
            n = int(body)
            if n == -1: return None
            data = self.file.read(n)
            assert self.file.read(2) == b'\r\n'
            return data.decode()
        if kind == b'*':
            return [self.read() for _ in range(int(body))]
        raise AssertionError(line)
    def cmd(self, *args):
        parts = [str(a).encode() for a in args]
        self.sock.sendall(b'*%d\r\n' % len(parts) + b''.join(
            b'$%d\r\n' % len(p) + p + b'\r\n' for p in parts))
        return self.read()

client = Client()
def start(image):
    docker('run', '-d', '--name', name, '--restart=no', '--network', 'bridge',
           '-p', '127.0.0.1::6379', '--memory', str(cfg['mem_limit']),
           '-v', name + ':/data', image, *cfg['command'])
    port = int(docker('port', name, '6379/tcp').rsplit(':', 1)[1])
    for _ in range(50):
        try:
            client.connect(port)
            assert client.cmd('AUTH', password) == 'OK'
            assert client.cmd('PING') == 'PONG'
            break
        except (OSError, RuntimeError):
            if hasattr(client, 'file'): client.close()
            time.sleep(.1)
    else: raise AssertionError('Redis not ready')
    guest = Client()
    guest.connect(port)
    try:
        guest.cmd('PING')
        raise AssertionError('Unauthenticated PING accepted')
    except RuntimeError as e:
        assert 'NOAUTH' in str(e)
    finally: guest.close()
    info = dict(line.split(':', 1) for line in client.cmd('INFO', 'persistence').splitlines()
                if ':' in line)
    for k, v in {'loading': '0', 'aof_enabled': '1', 'aof_last_write_status': 'ok'}.items():
        assert info[k] == v, (k, info[k])
    assert client.cmd('CONFIG', 'GET', 'maxmemory-policy') == ['maxmemory-policy', 'noeviction']
    # Keep the command sourced from Compose, and guard the wave's memory contract.
    assert cfg['command'][cfg['command'].index('--maxmemory') + 1] == '150mb'
    assert client.cmd('CONFIG', 'GET', 'maxmemory') == ['maxmemory', str(150 * 1024**2)]
    assert int(cfg['mem_limit']) == 256 * 1024**2

def stop():
    # A separate admin connection closes the still-connected workload client.
    admin = Client()
    admin.connect(client.sock.getpeername()[1])
    assert admin.cmd('AUTH', password) == 'OK'
    try:
        admin.cmd('SHUTDOWN', 'SAVE')
    except ConnectionError:
        pass  # Successful SHUTDOWN closes the connection without a reply.
    finally:
        admin.close()
    assert docker('wait', name) == '0'
    try:
        client.cmd('PING')
        raise AssertionError('Old connection survived shutdown')
    except (OSError, ConnectionError): pass
    client.close()
    docker('rm', name)

expires = {}
def seed():
    for db in (0, 1, 2):
        client.cmd('SELECT', db)
        assert client.cmd('SET', 'ttl', f'value-{db}', 'EX', 600) == 'OK'
        expires[db] = client.cmd('PEXPIRETIME', 'ttl')
        assert client.cmd('RPUSH', 'queue', f'job-{db}', 'next') == 2
        assert client.cmd('ZADD', 'scheduled', 42, f'job-{db}') == 1
        assert client.cmd('HSET', 'hash', 'state', f'pending-{db}') == 1
        assert client.cmd('XADD', 'stream', '1-0', 'job', f'job-{db}') == '1-0'

def verify(new=False):
    for db in (0, 1, 2):
        client.cmd('SELECT', db)
        assert client.cmd('DBSIZE') == (6 if new else 5)
        for key, typ in [('ttl', 'string'), ('queue', 'list'), ('scheduled', 'zset'),
                         ('hash', 'hash'), ('stream', 'stream')]:
            assert client.cmd('TYPE', key) == typ
            if key != 'ttl': assert client.cmd('PTTL', key) == -1
        assert client.cmd('GET', 'ttl') == f'value-{db}'
        assert client.cmd('PEXPIRETIME', 'ttl') == expires[db]
        assert 480000 < client.cmd('PTTL', 'ttl') <= 600000
        assert client.cmd('LRANGE', 'queue', 0, -1) == [f'job-{db}', 'next']
        assert client.cmd('ZRANGE', 'scheduled', 0, -1, 'WITHSCORES') == [f'job-{db}', '42']
        assert client.cmd('HGETALL', 'hash') == ['state', f'pending-{db}']
        assert client.cmd('XRANGE', 'stream', '-', '+') == [['1-0', ['job', f'job-{db}']]]
        if new:
            assert client.cmd('TYPE', 'new') == 'string'
            assert client.cmd('GET', 'new') == f'new-{db}'
            assert client.cmd('PTTL', 'new') == -1
        # Same client object reauthenticated after restart, exercising broker IO.
        assert client.cmd('LPUSH', 'roundtrip', f'job-{db}') == 1
        assert client.cmd('BRPOP', 'roundtrip', 1) == ['roundtrip', f'job-{db}']

docker('volume', 'create', name)
start(os.environ['REDIS_OLD_IMAGE'])
seed()
# Populate the RDB preamble inside multipart AOF, then leave an incremental tail.
assert client.cmd('CONFIG', 'GET', 'aof-use-rdb-preamble') == ['aof-use-rdb-preamble', 'yes']
client.cmd('BGREWRITEAOF')
for _ in range(100):
    info = client.cmd('INFO', 'persistence')
    if 'aof_rewrite_in_progress:0' in info and 'aof_last_bgrewrite_status:ok' in info:
        break
    time.sleep(.1)
else: raise AssertionError('AOF rewrite did not complete')
client.cmd('SET', 'incremental-tail', 'synthetic')
assert client.cmd('DEL', 'incremental-tail') == 1
verify()
stop()
start(cfg['image'])
verify()
for db in (0, 1, 2):
    client.cmd('SELECT', db)
    assert client.cmd('SET', 'new', f'new-{db}') == 'OK'
stop()
start(cfg['image'])
verify(new=True)
stop()
print(f'PASS: Redis upgrade, auth, AOF, types/values/TTLs in DBs 0/1/2, reconnect and second restart ({time.monotonic()-started:.1f}s)')
PY
