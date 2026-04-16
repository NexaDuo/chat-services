---
created: 2026-04-16T05:09:34.362Z
title: Harden repo for public GitHub security
area: general
files:
  - .env.example:16-18,132
  - edge/cloudflare-worker/wrangler.jsonc:10,22
  - automation/initial-setup.js:9-12
  - middleware/src/handlers/chatwoot-webhook.ts:60-230
  - deploy/docker-compose.shared.yml:21-23
  - deploy/docker-compose.chatwoot.yml:52-54
  - deploy/docker-compose.dify.yml:49-50,120,133
  - deploy/docker-compose.nexaduo.yml:21-22,43-44,79-80
  - agents/self-healing/src/index.ts:20-22
---

## Problem

Security audit identified blockers for making this repository safely public on GitHub. The most urgent issues are a committed shared secret reused across environments, insecure default admin credential fallback, missing webhook request authentication, risky exposed service ports, wildcard CORS on Dify API, disabled plugin signature verification, weak DB fallback credentials in self-healing agent, and unpinned `latest` images.

These create a realistic path to unauthorized access, tenant data leakage, admin takeover, service abuse, and supply-chain risk if copied to production settings.

## Solution

1. Rotate and remove hardcoded secrets from tracked files; move runtime secrets to secret managers/CI vars only.
2. Remove insecure credential fallbacks and fail fast when required env vars are missing.
3. Add webhook auth (signature or shared-secret + replay protection) for Chatwoot webhook endpoint.
4. Restrict published ports to only required ingress and enforce origin protection controls.
5. Replace wildcard CORS with explicit allowlists.
6. Re-enable plugin signature verification.
7. Remove default `postgres:postgres` fallback and require explicit DB credentials.
8. Pin all container images to immutable versions/digests.
