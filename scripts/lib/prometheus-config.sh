#!/usr/bin/env bash
# Caller provides REPO_ROOT and dc(). Directory mount includes future rule files.
reload_prometheus_config() {
  local container checksum previous
  container="$(dc ps -q --status running prometheus)" || return
  [[ -n "$container" ]] || { echo 'Prometheus is not running' >&2; return 1; }
  checksum="$(cd "$REPO_ROOT/observability/prometheus" &&
    find . -type f ! -name README.md -print0 | LC_ALL=C sort -z |
    xargs -0 sha256sum | sha256sum | awk '{print $1}')" || return
  previous="$(docker exec "$container" cat /prometheus/config.sha256 2>/dev/null || true)"
  [[ "$checksum" != "$previous" ]] || return 0
  # Reject invalid edits before interrupting the running process.
  docker exec "$container" promtool check config /etc/prometheus/prometheus.yml || return
  echo 'Prometheus config changed; restarting only prometheus.'
  dc restart --no-deps prometheus || return
  # Restart success alone is not readiness. Leave the marker stale on failure.
  local attempt
  for attempt in {1..15}; do
    if docker exec "$container" wget -qO- -T 2 http://127.0.0.1:9090/-/ready >/dev/null 2>&1; then
      printf '%s\n' "$checksum" | docker exec -i "$container" sh -c \
        'cat > /prometheus/config.sha256.tmp && mv /prometheus/config.sha256.tmp /prometheus/config.sha256'
      return
    fi
    sleep 1
  done
  echo 'Prometheus did not become ready; checksum not saved' >&2
  return 1
}
