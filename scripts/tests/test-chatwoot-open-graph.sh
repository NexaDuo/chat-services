#!/usr/bin/env bash
# Issue #273: exercise deploy/open_graph.rb against the Ruby and Rack shipped in
# the pinned Chatwoot image, without .env, network, database or live resources.
# The Playwright spec (onboarding/tests/19-chatwoot-open-graph.spec.ts) covers
# the booted stack; this covers what a browser cannot see: byte-for-byte
# passthrough, Content-Length, body lifecycle, the self-disabling config and
# the fail-open tenant lookup. The lookup is fed the same golden payload the
# middleware's own test pins its response to (middleware/src/handlers/tenant.test.ts).
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

image=$(sed -n '/^  chatwoot-rails:/,/^  chatwoot-sidekiq:/s/^    image: *//p' "$ROOT/deploy/docker-compose.chatwoot.yml")
[[ "$image" == chatwoot/chatwoot:*@sha256:* ]] || { echo "could not read the pinned chatwoot-rails image: '$image'" >&2; exit 1; }

# The committed images must be what the tags will claim they are.
python3 - "$ROOT"/deploy/og-images/*.png <<'PY'
import os, struct, sys
for path in sys.argv[1:]:
    data = open(path, 'rb').read(24)
    name = os.path.basename(path)
    assert data[:8] == b'\x89PNG\r\n\x1a\n' and data[12:16] == b'IHDR', f'{name} is not a PNG'
    size = struct.unpack('>II', data[16:24])
    assert size == (1200, 630), f'{name} is {size[0]}x{size[1]}, expected 1200x630'
    assert os.path.getsize(path) < 300 * 1024, f'{name} is larger than 300 KB'
    print(f'deploy/og-images/{name}: 1200x630 PNG, {os.path.getsize(path)} bytes')
assert any(os.path.basename(p) == 'default.png' for p in sys.argv[1:]), 'deploy/og-images/default.png is missing'
PY

# bundle exec from /app resolves the image's own Gemfile.lock (same Rack as Puma).
timeout 120s docker run --rm --network none --log-driver none \
  -v "$ROOT/deploy/open_graph.rb:/contract/open_graph.rb:ro" \
  -v "$ROOT/scripts/tests/chatwoot-open-graph-contract.rb:/contract/contract.rb:ro" \
  -v "$ROOT/scripts/tests/fixtures/tenant-branding-response.json:/contract/golden.json:ro" \
  -e OPEN_GRAPH_INITIALIZER=/contract/open_graph.rb -e OPEN_GRAPH_GOLDEN=/contract/golden.json \
  -w /app --entrypoint bundle "$image" exec ruby /contract/contract.rb
