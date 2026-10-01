#!/usr/bin/env bash
# Shared by the host health check and the isolated storage-upgrade regression.
tempo_ready() {
  docker exec "$1" wget -qO- -T 5 http://tempo:3200/ready >/dev/null 2>&1
}
