# Robust GCP & Grafana Logging Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist Promtail log positions. Prevent duplicate log push. Fix Loki errors.

**Architecture:** Create persistent volume for Promtail positions. Update Promtail configuration. Prevent re-reading logs on restart.

**Tech Stack:** Grafana Promtail, Grafana Loki, Docker Compose.

---

### Task 1: Update Promtail Configuration

**Files:**
- Modify: `observability/promtail/promtail.yaml:5-6`

- [ ] **Step 1: Edit positions configuration**

Modify position file path. Use persistent path `/var/promtail/positions.yaml` instead of `/tmp/positions.yaml`.

Code change in `observability/promtail/promtail.yaml`:
```diff
 positions:
-  filename: /tmp/positions.yaml
+  filename: /var/promtail/positions.yaml
```

- [ ] **Step 2: Commit changes**

Run:
```bash
git add observability/promtail/promtail.yaml
git commit -m "config: update promtail position path"
```

---

### Task 2: Update Production Docker Compose

**Files:**
- Modify: `deploy/docker-compose.nexaduo.yml:53-55,103-107`

- [ ] **Step 1: Add volume mount to Promtail service**

Add persistent volume `/var/promtail` to Promtail service.

Code change in `deploy/docker-compose.nexaduo.yml`:
```diff
   promtail:
     image: grafana/promtail:3.1.0
     restart: unless-stopped
     command: -config.file=/etc/promtail/promtail.yaml
     volumes:
       - /opt/nexaduo/observability/promtail/promtail.yaml:/etc/promtail/promtail.yaml:ro
       - /var/run/docker.sock:/var/run/docker.sock:ro
+      - promtail-data:/var/promtail
     networks:
       - chat-network
```

- [ ] **Step 2: Declare named volume**

Declare `promtail-data` named volume in volumes section.

Code change in `deploy/docker-compose.nexaduo.yml` (at the bottom):
```diff
 volumes:
   evolution-instances:
   loki-data:
   grafana-data:
   prometheus-data:
+  promtail-data:
```

- [ ] **Step 3: Commit changes**

Run:
```bash
git add deploy/docker-compose.nexaduo.yml
git commit -m "deploy: persist promtail positions in production"
```

---

### Task 3: Update Local Override Docker Compose

**Files:**
- Modify: `docker-compose.yml:99-102`

- [ ] **Step 1: Add volume mount to Promtail local service**

Map local volume to match production environment.

Code change in `docker-compose.yml`:
```diff
   promtail:
     volumes:
       - ${PWD}/observability/promtail/promtail.yaml:/etc/promtail/promtail.yaml:ro
+      - promtail-data:/var/promtail
```

- [ ] **Step 2: Declare named volume locally**

Add volumes section at bottom of file if missing, or update if exists.

Code change in `docker-compose.yml` (at the bottom):
```diff
+volumes:
+  promtail-data:
```

- [ ] **Step 3: Commit changes**

Run:
```bash
git add docker-compose.yml
git commit -m "deploy: persist promtail positions locally"
```

---

### Task 4: Deploy and Verify

**Files:**
- Test: Production GCE VM state.

- [ ] **Step 1: Copy updated files to GCE VM**

Deploy configuration files using standard sync/deploy pipeline.
Run:
```bash
./scripts/deploy-production.sh
```
Expected output: Deployment completed successfully.

- [ ] **Step 2: Verify Promtail positions file creation**

Verify that positions file exists and is active on host.
Run:
```bash
gcloud compute ssh ubuntu@nexaduo-chat-services --project=nexaduo-492818 --zone=us-central1-b --tunnel-through-iap --command "sudo docker exec -it promtail-dsgwuwrdnmue9nhdkeovb6tx ls -l /var/promtail/positions.yaml"
```
Expected output: File exists with read/write permissions.

- [ ] **Step 3: Check Promtail container logs**

Verify zero HTTP 400 errors or duplicate log push rejections.
Run:
```bash
gcloud compute ssh ubuntu@nexaduo-chat-services --project=nexaduo-492818 --zone=us-central1-b --tunnel-through-iap --command "sudo docker logs promtail-dsgwuwrdnmue9nhdkeovb6tx"
```
Expected output: No "entry too far behind" errors. No "final error sending batch" status=400.
