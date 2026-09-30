#!/usr/bin/env bash
# Caller provides REPO_ROOT and dc(). Invoked by up/bootstrap or reload-alloy.
reload_alloy_config() {
  local container checksum previous
  container="$(dc ps -q --status running alloy)"
  [[ -n "$container" ]] || { echo 'Alloy is not running' >&2; return 1; }
  checksum="$(cd "$REPO_ROOT/observability/alloy" &&
    find . -type f ! -name README.md -print0 | LC_ALL=C sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}')"
  previous="$(docker exec "$container" cat /var/lib/alloy/config.sha256 2>/dev/null || true)"
  [[ "$checksum" != "$previous" ]] || return 0
  echo 'Alloy config changed; restarting only alloy to load the directory mount.'
  dc restart --no-deps alloy || return
  # Save only after a successful restart, so failures are retried next invocation.
  printf '%s\n' "$checksum" | docker exec -i "$container" sh -c \
    'cat > /var/lib/alloy/config.sha256.tmp && mv /var/lib/alloy/config.sha256.tmp /var/lib/alloy/config.sha256'
}
