---
name: sre-auditor
description: Performs routine SRE health checks, parses container logs, runs stack diagnostic scripts, and reports infrastructure drift or errors.
---

# SRE Auditor Skill: NexaDuo Stack Diagnostics

This skill equips the agent to perform routine SRE inspections, run system diagnostics, evaluate system metrics, and audit container logs for the NexaDuo Chat Services stack.

---

## 🎯 Objectives
* Verify stack health, container lifecycle, and network topology.
* Analyze application, database, and observability logs to catch warning patterns early.
* Automate the creation of issues and documentation when system anomalies or degradations are found.
* Enforce SRE best practices (e.g., Redis overcommit settings, DB migrations sanity, Grafana backend persistence).

---

## 🛠️ Diagnostics & Verification Runbook

Follow these steps when tasked with auditing the stack:

### Step 1: Run the Central Health Check Script
Always begin by executing the centralized diagnostic tool in the workspace:
* [health-check-all.sh](file:///home/ubuntu-24/repos/NexaDuo/chat-services/scripts/health-check-all.sh)

Run it from the workspace root:
```bash
./scripts/health-check-all.sh
```
* **If it exits with 0:** The basic connectivity, ports, network memberships, and services are running and accessible.
* **If it exits with 1 (fails):** The failing check and endpoint will be highlighted in `stderr`. Proceed to step 2 to parse logs.

### Step 2: Query Container States and Mappings
Inspect docker containers to evaluate restart loops or port binds:
```bash
docker ps -a --filter "label=coolify.managed=true"
```
Look for containers with `Status: Restarting (...)` or health statuses showing `unhealthy`.

### Step 3: Log Auditing & Known Error Patterns
Run searches across container logs or log bundles (such as `job_log.txt`) for these known SRE issues:

#### A. Redis Memory Overcommit Warning
* **Search Pattern:** `Memory overcommit must be enabled!`
* **Fix:** Ensure [bootstrap-coolify.sh](file:///home/ubuntu-24/repos/NexaDuo/chat-services/scripts/bootstrap-coolify.sh) configures:
  ```bash
  sudo sysctl vm.overcommit_memory=1
  echo "vm.overcommit_memory = 1" | sudo tee -a /etc/sysctl.conf
  ```

#### B. Chatwoot Database Migration Race Condition
* **Search Pattern:** `relation "installation_configs" does not exist`
* **Fix:** Wrap the AI Agents SDK boot configuration in Chatwoot initializers to check for table existence before querying (`ActiveRecord::Base.connection.table_exists?`).

#### C. Grafana SQLite Database Lock
* **Search Pattern:** `Database locked, sleeping then retrying`
* **Fix:** Update Grafana environment in [docker-compose.yml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/docker-compose.yml) to connect to the shared Postgres instance under a dedicated `grafana` database.

#### D. Grafana Built-in Plugin Registration Error
* **Search Pattern:** `plugin xychart is already registered`
* **Fix:** Remove the duplicate manual installation of `xychart` from the configuration environment variables.

#### E. Loki Querier HTTP 500 Failures
* **Search Pattern:** `metrics.go` log line with `status=500` for Loki range queries.
* **Fix:** Inspect loki logs, verify permissions on `/var/loki/chunks`, and tune the `limits_config` settings in [loki.yaml](file:///home/ubuntu-24/repos/NexaDuo/chat-services/observability/loki/loki.yaml).

---

## 📈 Logging Issues

When SRE drifts or logs warnings are discovered:
1. Document the issue in a local markdown artifact detailing:
   * Component affected.
   * Log snippets/warnings.
   * Proposed fix (with file links).
2. Automate issue creation on GitHub using the GitHub CLI (`gh`):
   ```bash
   gh issue create --repo NexaDuo/chat-services --title "[SRE] <Title>" --body "<Markdown Description>"
   ```
3. Report back to the user with the URLs of the created issues and highlight immediate remediation choices.
