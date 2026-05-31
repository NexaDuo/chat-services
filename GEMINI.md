# NexaDuo Chat Services — Engineering Standards

## Coolify v4 + Terraform — Golden Rules

To ensure status synchronization, functional UI (Logs/Terminal), and stable deployments:

1.  **No `container_name`**: Never use the `container_name` directive in Docker Compose files. Coolify v4 expects to manage container names (e.g., `serviceName-uuid`). Hardcoding them breaks the UI.
2.  **Official API for Deployments**: Avoid manual `docker compose up` on the VM. Always use the Coolify API (`POST /api/v1/deploy?uuid=...`) to ensure the internal state and the Docker state are in sync.
3.  **Permissions**: The SSH user used by Coolify (default: `ubuntu`) **must** be in the `docker` group (`usermod -aG docker ubuntu`) to perform status checks.
4.  **SSH Identity**: Ensure the Coolify container has the host's fingerprint in `known_hosts` and that its public key is authorized in the host's `authorized_keys`.
5.  **Terraform Lifecycle**: Use `ignore_changes` for `server_uuid`, `project_uuid`, etc., to avoid 422 errors during updates. **Note:** The current provider has bugs updating the `compose` attribute directly.
6.  **Absolute Paths**: When mounting host files, use absolute paths (e.g., `/opt/nexaduo/...`) to avoid Mylar/Coolify parsing errors that can result in malformed volume specs.

---

## Local Development in WSL2 (Docker Desktop Integration)

When running the stack or Coolify locally in Windows Subsystem for Linux (WSL2):

1. **Disable Native Docker Daemon:** The native Linux `docker.service` and `docker.socket` managed by systemd inside the WSL distro must be disabled to avoid port and socket mapping conflicts:
   ```bash
   sudo systemctl stop docker.service docker.socket
   sudo systemctl disable docker.service docker.socket
   ```
2. **Use Docker Desktop WSL2 Integration:** Configure Docker Desktop on Windows (Settings > Resources > WSL integration) to expose its daemon to your WSL distro. This mounts a unified `/var/run/docker.sock` that communicates with the Windows host.
3. **Automated Setup Script:** Run the helper script `scripts/setup-local-wsl.sh` to automatically clean up native daemon conflicts, fix socket permissions, and verify integration.
4. **Hosts Mapping:** Ensure local domains (e.g., `chat.nexaduo.com`) are mapped to `127.0.0.1` in the Windows hosts file (`C:\Windows\System32\drivers\etc\hosts`) to access them through Traefik.

---

*Last updated: 2026-05-31*

