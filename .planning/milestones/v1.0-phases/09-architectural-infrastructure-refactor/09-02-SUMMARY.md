---
phase: 09-architectural-infrastructure-refactor
plan: 02
subsystem: infrastructure/scripts
tags: ["coolify", "gcp", "bootstrap", "automation"]
requires: ["09-01"]
provides: ["Automated bridging between Foundation and Tenant layers"]
affects: ["GCP Secret Manager", "Coolify VM"]
tech-stack: ["bash", "gcloud", "php-tinker"]
key-files: ["scripts/bootstrap-coolify.sh"]
decisions:
  - "Integrated GCP Secret Manager (SSOT) into the bootstrap flow to decouple VM provisioning from tenant configuration."
  - "Used PHP Tinker to generate Sanctum tokens directly on the VM, ensuring identity and access control for the Coolify API."
metrics:
  duration: "15m"
  completed_date: "2024-04-18"
---

# Phase 09 Plan 02: Bootstrap Script Summary

Refined the `scripts/bootstrap-coolify.sh` script to serve as the bridge between the Foundation (VM/Infra) and Tenant (Coolify apps) layers.

## Key Accomplishments

- **Robust Secret Management**: Added an `ensure_secret` helper to create GCP Secret Manager secrets (`coolify_api_token`, `coolify_destination_uuid`, `coolify_url`) if they don't already exist, ensuring the bootstrap process is self-healing.
- **SSOT Integration**: Automated the population of GCP Secret Manager with the Coolify API token, destination UUID, and API URL, providing a Single Source of Truth for the Tenant layer's Terraform provider.
- **Enhanced Reliability**: Implemented pre-flight checks for `gcloud` and connectivity, along with a retry loop to wait for the Coolify API to become ready.
- **Secure Token Generation**: Used direct PHP Tinker commands via SSH IAP to generate Sanctum tokens without exposing them in logs or requiring manual web UI interaction.
- **Provisioning Prep**: Added steps to create the Docker network `nexaduo-network` and upload `01-init.sql` for future database provisioning.

## Deviations from Plan

None - plan executed exactly as written.

## Self-Check: PASSED

- [x] Script passes syntax check (`bash -n`).
- [x] Script includes logic to create secrets if missing.
- [x] Script handles the `coolify_url` secret.
- [x] Commits recorded.
