# NexaDuo: Agent Instructions & Lessons Learned

## Deployment Strategies to AVOID
- **Coolify Terraform Provider for Service Stacks:** Extremely brittle. Fails with `422 Unprocessable Content` on updates to immutable fields like `environment_name`, even with `ignore_changes`. Use for `foundation` only.
- **Coolify Dynamic Routing for Multi-Container Stacks:** Unreliable for complex setups (Dify, NexaDuo Stack). Routes often 404 or 502 after redeploys. Use deterministic fallback YAMLs in `/data/coolify/proxy/dynamic/`.
- **Relative Volume Paths in Coolify Compose:** Causes resolution errors (containers stuck in `Created`). Use absolute paths or fixed host variables like `/opt/nexaduo`.
- **Hardcoded Localhost in Tests:** Production tests must use environment variables (`CHATWOOT_URL`, etc.) to support both local and remote validation.

## Recommended Workflow
1. **Foundation:** Terraform (Official GCP/Cloudflare providers).
2. **App Layer:** Scripted `scp` of `.env`/`compose` + `ssh docker compose up -d`.
3. **Routing:** Scripted generation of Traefik dynamic configs.
4. **Validation:** Playwright tests with production URLs.
