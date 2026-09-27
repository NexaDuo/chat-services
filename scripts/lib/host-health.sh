#!/usr/bin/env bash
# Shared host guards (issue #225). Never source production secrets here.
require_desktop_engine() {
  local engine
  if ! engine="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)"; then
    echo "FAIL: cannot query Docker engine; check Docker CLI/PATH, Desktop WSL integration and docker context." >&2
  elif [[ "$engine" == "Docker Desktop"* ]]; then
    return 0
  elif [[ "${ALLOW_NON_DESKTOP_ENGINE:-0}" == "1" ]]; then
    echo "WARN: non-Desktop engine allowed explicitly (CI only)." >&2
    return 0
  else
    echo "FAIL: Docker engine must report OperatingSystem starting with Docker Desktop." >&2
  fi
  echo "Run: docker info --format '{{.OperatingSystem}}'; systemctl is-enabled docker.socket docker (both must report masked)." >&2
  echo "Repair WSL integration/native daemon via https://github.com/alexandre-machado/wsl-setup/blob/main/scripts/docker.sh; ALLOW_NON_DESKTOP_ENGINE=1 is for CI only." >&2
  return 1
}

show_health_failure() {
  local marker="${HOME}/nexaduo-local/.health-last-fail"
  if [[ -f "$marker" ]]; then
    echo "!!! PREVIOUS SCHEDULED HOST HEALTH FAILURE: $marker !!!" >&2
    cat "$marker" >&2
    echo "Inspect ~/nexaduo-local/health-check.log; rerun scripts/scheduled-health-check.sh after repair." >&2
  fi
}
