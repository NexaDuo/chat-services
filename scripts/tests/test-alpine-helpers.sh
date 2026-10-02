#!/usr/bin/env bash
# W6b: synthetic ownership/archive fixtures only; no host .env or live resources.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
export ALPINE_TEST_ROOT="$ROOT"
export ALPINE_TEST_NAME="w6b-alpine-$(cat /proc/sys/kernel/random/uuid)"
config=$(docker compose --env-file /dev/null -p "$ALPINE_TEST_NAME" \
  -f "$ROOT/deploy/docker-compose.shared.yml" \
  -f "$ROOT/deploy/docker-compose.dify.yml" config --format json 2>/dev/null)
export ALPINE_INIT_CONFIG="$(jq -ce '.services["dify-init"]' <<<"$config")"
# Source only defaults/guard definitions, before any Docker or .env access.
unset BACKUP_HELPER_IMAGE
BACKUP_HOST_TEST_MODE=1 source "$ROOT/scripts/backup-host.sh"
export BACKUP_HELPER_IMAGE
image=$(jq -er '.image' <<<"$ALPINE_INIT_CONFIG")
for img in "$image" "$BACKUP_HELPER_IMAGE"; do
  [[ $img =~ ^alpine:3\.24\.[0-9]+@sha256:[a-f0-9]{64}$ ]]
  docker pull "$img" >/dev/null
done
cleanup() {
  local status=$?
  trap - EXIT
  timeout 4s docker rm -f "$ALPINE_TEST_NAME" >/dev/null 2>&1 || true
  timeout 4s docker volume rm "$ALPINE_TEST_NAME-init" "$ALPINE_TEST_NAME-src" \
    "$ALPINE_TEST_NAME-dst" >/dev/null 2>&1 || true
  exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
# 48s + 2s kill grace + 8s cleanup <60s, excluding pulls.
timeout --signal=TERM --kill-after=2s 48s python3 - <<'PY'
import gzip, io, json, os, pathlib, re, shlex, subprocess, tarfile, time
started = time.monotonic()
cfg = json.loads(os.environ['ALPINE_INIT_CONFIG'])
name = os.environ['ALPINE_TEST_NAME']
helper = os.environ['BACKUP_HELPER_IMAGE']
root = pathlib.Path(os.environ['ALPINE_TEST_ROOT'])

def docker(*args, data=None):
    return subprocess.check_output(['docker', *args], input=data, timeout=10)

def run(volume, image, *args, data=None, target='/data', readonly=False):
    return docker('run', '--rm', '-i', '--name', name, '--network', 'none',
                  '-v', f'{volume}:{target}' + (':ro' if readonly else ''),
                  image, *args, data=data)

volumes = [name + '-' + suffix for suffix in ('init', 'src', 'dst')]
for volume in volumes:
    docker('volume', 'create', volume)
seed = '''mkdir -p /data/sub
printf 'synthetic payload\\n' > /data/sub/file
printf 'second\\n' > '/data/space name'
ln -s sub/file /data/link
chown -R 2345:3456 /data
chmod 750 /data
chmod 700 /data/sub
chmod 600 /data/sub/file
chmod 640 '/data/space name'
'''
# lstat (no -L) preserves symlink ownership/type; file sizes are compared below.
manifest = '''cd /data && find . -exec stat -c '%n|%F|%a|%u|%g|%s' '{}' ';' | sort'''
for volume in volumes[:2]:
    run(volume, helper, 'sh', '-ec', seed)
initial = run(volumes[0], helper, 'sh', '-ec', manifest).decode()
assert all(row.split('|')[3:5] == ['2345', '3456'] for row in initial.splitlines())
expected = initial.replace('|2345|3456|', '|1001|1001|')
mounts = [v for v in cfg['volumes'] if v.get('source') == 'dify-api-storage']
assert len(mounts) == 1
for _ in range(2):
    run(volumes[0], cfg['image'], *(cfg.get('entrypoint') or []), *cfg['command'],
        target=mounts[0]['target'])
    actual = run(volumes[0], helper, 'sh', '-ec', manifest).decode()
    assert actual == expected, (expected, actual)

# Extract the production invocation, not a second copy of its flags. Fail on drift.
source = (root / 'scripts/backup-host.sh').read_text()
match = re.search(r'if docker run --rm -v "\$\{vol\}:/data:ro" "\$BACKUP_HELPER_IMAGE" \\\n\s+(tar [^\n]+?) > "\$OUT"', source)
assert match, 'backup tar invocation changed; review extraction'
command = shlex.split(match[1])
archive = run(volumes[1], helper, *command, readonly=True)
with tarfile.open(fileobj=io.BytesIO(archive), mode='r:gz') as tar:
    entries = {m.name: m for m in tar.getmembers()}
    assert set(entries) == {'.', './sub', './sub/file', './space name', './link'}, entries
    assert entries['./sub/file'].size == len(b'synthetic payload\n')
    assert entries['./sub/file'].mode == 0o600
    assert entries['./link'].issym() and entries['./link'].linkname == 'sub/file'
    assert all((m.uid, m.gid) == (2345, 3456) for m in entries.values())
assert run(volumes[2], helper, 'sh', '-ec', 'ls -A /data') == b''
# BusyBox restores the volume root metadata; Docker cp -a also preserves symlink
# ownership (BusyBox tar alone leaves links owned by root, including in 3.20).
run(volumes[2], helper, 'tar', 'xzf', '-', '-C', '/data', data=archive)
docker('run', '-d', '--name', name, '--network', 'none',
       '-v', volumes[2] + ':/data', helper, 'sleep', '48')
docker('cp', '-a', '-', name + ':/data', data=gzip.decompress(archive))
docker('rm', '-f', name)
before = run(volumes[1], helper, 'sh', '-ec', manifest, readonly=True)
after = run(volumes[2], helper, 'sh', '-ec', manifest, readonly=True)
assert before == after, (before, after)
assert run(volumes[2], helper, 'readlink', '/data/link') == b'sub/file\n'
assert run(volumes[2], helper, 'cat', '/data/sub/file') == b'synthetic payload\n'
assert run(volumes[2], helper, 'cat', '/data/space name') == b'second\n'
print(f'PASS: Compose init ownership/modes/idempotency and backup tar metadata/content round-trip ({time.monotonic()-started:.1f}s)')
PY
