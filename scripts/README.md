# Operational Scripts

This directory contains utilities for management, deployment, and maintenance of the NexaDuo stack.

## Production Deployment

### `deploy-production.sh`
The main orchestrator. Manages Terraform execution for the foundation and calls the bootstrap and application deployment scripts.

### `deploy-tenant-direct.sh`
The deployment engine for the application layer. Transfers `docker-compose.yml` and `.env` files (populated with GCP secrets) via SCP and executes the startup command via SSH on the VM.

### `bootstrap-coolify.sh`
Configures the newly created VM: installs Coolify, generates initial API tokens, and synchronizes necessary secrets to GCP Secret Manager.

### `refresh-coolify-routes.sh`
Utility to force Traefik route updates in Coolify. Essential when new containers are created and the dynamic proxy doesn't detect them automatically.

## Maintenance and Backup

### `backup.sh`
Performs `pg_dump` of all stack databases (`chatwoot`, `dify`, `dify_plugin`, `evolution`) via `docker compose exec` and stores them in `./backups/` (or `$BACKUP_DIR`).

### `generate-env.sh`
Generates the `.env` file from `.env.example`, filling in random secrets and a robust password for Chatwoot.

## Validation

### `validate-stack.sh`
Unified script for local environment. Tears down the current stack, clears volumes, brings it up again, waits for health checks, runs onboarding, and executes smoke tests.

### `health-check-all.sh`
Verifies availability of all stack endpoints in production.
