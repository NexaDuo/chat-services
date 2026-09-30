#!/usr/bin/env bash
# Execute in a sibling with BusyBox wget (middleware), never inside Loki.
# Optional URL permits isolated regression fixtures; HTTP errors fail closed.
loki_ready() {
  docker exec "$1" wget -qO- -T 5 "${2:-http://loki:3100/ready}" >/dev/null 2>&1
}
