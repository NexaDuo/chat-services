# NexaDuo Chat Services: Historical SRE & Troubleshooting Synthesis

This document synthesizes the engineering challenges, failures, and structural fixes resolved in this repository over the last two months. It serves as a regression prevention guide for developers and SRE agents.

---

## 🛠️ Infrastructure & Docker Failures

### 1. PostgreSQL Disk Init Failure (`lost+found` conflict)
* **Symptom:** Postgres container fails to initialize (`initdb`) and crashes during first run when attached to a newly formatted ext4 block storage disk.
* **Root Cause:** In ext4 partitions, the operating system automatically creates a `lost+found` directory at the root of the mount point. PostgreSQL's `initdb` command aborts if it finds any files or directories in the target data directory.
* **Correction:** Set the `PGDATA` environment variable to a subfolder of the mounted disk volume (e.g., `/var/lib/postgresql/data/pgdata`) rather than the mount root itself in [deploy/docker-compose.shared.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/deploy/docker-compose.shared.yml).

### 2. WSL2 Docker Desktop Port & Socket Mapping Conflicts
* **Symptom:** Local workspace setup fails to map ports or resolve localhost domains inside WSL2.
* **Root Cause:** The native systemd docker daemon running inside the WSL2 distro (`docker.service`) conflicts with the Docker Desktop integrated daemon mapping socket `/var/run/docker.sock`.
* **Correction:** Disable the native Linux daemon inside the WSL2 systemd setup using `sudo systemctl disable --now docker.service docker.socket` and leverage the helper script [setup-local-wsl.sh](file:///home/ubuntu-24/repos/NexaDuo/chat-services/scripts/setup-local-wsl.sh).

### 3. Coolify projecting / Staging project projects 404s
* **Symptom:** Workspace-driven Terraform runs fail with HTTP 404 when applying resources in Coolify for non-production environments.
* **Root Cause:** Coolify creates default projects keyed under `production` space names. If Terraform attempts to pass the current workspace (e.g., `staging`) as `environment_name`, Coolify cannot locate the workspace and returns 404.
* **Correction:** Standardize HCL to map Coolify `environment_name` to `production` for all workspaces, while distinguishing actual resources dynamically using variables (e.g., `service_suffix`).

---

## 🔐 Authentication & Integration (Chatwoot OAuth)

### 4. Chatwoot Google OAuth OmniAuth 2.0+ POST specification
* **Symptom:** Google login button displays, but clicking it results in silent failures or routing loops.
* **Root Cause:** OmniAuth 2.0+ deprecated GET requests for OAuth callback triggers to prevent CSRF attacks. Chatwoot requires explicit container-level configurations to allow GET/POST callbacks, and Playwright tests must trigger OAuth login buttons using POST requests.
* **Correction:** Configure OmniAuth allowed request methods (`allowed_request_methods = [:post, :get]`) in Chatwoot initializers on container startup, map `GOOGLE_CLIENT_ID` to the proper environment vars, and parameterize Playwright test selectors to click elements triggering POST sequences.

---

## 📊 Observability (Loki & Promtail)

### 5. Promtail Config Inode Swap Silent Failures
* **Symptom:** Promtail configurations are edited on the host, but the running container continues to push log formats from the old configuration.
* **Root Cause:** Promtail bind-mounts a single file `promtail.yaml`. On Linux, replacing this file via commands like `rm` and `mv` during deployments changes its file system inode. A running docker container keeps the open file descriptor pointing to the old inode, silently ignoring the new configuration.
* **Correction:** The VM bootstrap script must calculate the sha256 checksum of the configuration file and explicitly restart the Promtail container (`docker restart <container_name>`) whenever the config changes.

### 6. Numeric Pino Log Levels Normalization
* **Symptom:** Logs from Node.js applications (using Pino logger) map severity levels to numbers (e.g. `30` for info, `50` for error). Grafana and Loki unifed dashboard metrics could not capture or query these levels accurately.
* **Correction:** Configured a template pipeline stage in [promtail.yaml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/observability/promtail/promtail.yaml) to normalize numeric Pino codes to standardized uppercase strings (`30` -> `INFO`, `40` -> `WARN`, `50` -> `ERROR`, `60` -> `FATAL`).

---

## ☁️ Compute & Resource Limitations

### 7. CPU Throttling and Out-Of-Memory (OOM) on e2-medium
* **Symptom:** Deployments on non-production VMs fail to bootstrap. Dify API workers crash or freeze during alembic database migrations.
* **Root Cause:** A complete NexaDuo environment spawns 13+ containers. Running these on an `e2-medium` (4GB RAM) exhausts kernel memory, triggering the OOM killer or severe CPU throttling.
* **Correction:** Configure staging/non-production VM machine types to at least `e2-standard-2` (8GB RAM) to allow simultaneous database provisioning and migrations.
