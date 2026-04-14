# Phase 02: Management & Edge Connectivity - Research

**Researched:** 2025-01-24
**Domain:** Infrastructure Orchestration & Edge Routing
**Confidence:** HIGH

## Summary

This phase focuses on establishing the management layer (Coolify v4) and securing the origin server using a "portless" ingress architecture via Cloudflare Tunnels (Argo). By the end of this phase, the GCP VM will be isolated from the public internet (except for SSH via Google IAP), and all application traffic will flow through a secure, authenticated tunnel.

**Primary recommendation:** Use specific Cloudflare Tunnel hostname mappings for unified subdomains (`coolify.nexaduo.com`, `chat.nexaduo.com`, `dify.nexaduo.com`) to the internal Coolify proxy. This avoids the use of wildcard subdomains and supports the shift to path-based routing (`chat.nexaduo.com/{tenant}/`) managed at the edge by Cloudflare Workers.

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Coolify | v4 (latest) | Self-hosted PaaS / Orchestrator | Simple multi-container management, built-in backup handling, and Docker Compose support. |
| Cloudflared | latest | Cloudflare Tunnel Connector | Establishes secure outbound connection to Cloudflare, eliminating the need for open inbound ports. |
| Terraform | v1.14.x | Infrastructure as Code | Consistent provisioning of Cloudflare DNS and (optionally) Tunnel resources. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| GCS (S3-Compatible) | — | Backup Storage | Off-site storage for database and application backups via GCS HMAC interoperability. |

**Installation:**
```bash
# Coolify v4 One-line Installer
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash
```
*Note: This is already integrated into the `metadata_startup_script` of the GCP VM provisioned in Phase 1.*

## Architecture Patterns

### Recommended Project Structure
```
infrastructure/
├── terraform/
│   ├── modules/
│   │   ├── cloudflare-dns/      # DNS & Wildcard records
│   │   └── cloudflare-tunnel/   # Tunnel provisioning (if automated)
│   └── envs/
│       └── production/          # Main environment
```

### Pattern 1: Portless Ingress (Cloudflare Tunnels)
**What:** Use the `cloudflared` agent to connect the GCP VM to Cloudflare's edge without opening firewall ports 80 or 443.
**When to use:** Always, for maximum origin security.
**Implementation:**
1. Create Tunnel in Cloudflare Zero Trust Dashboard.
2. Deploy `cloudflared` as a Docker container in Coolify using the `CLOUDFLARE_TUNNEL_TOKEN`.
3. Map unified subdomains (`coolify.nexaduo.com`, `chat.nexaduo.com`, `dify.nexaduo.com`) to the internal Coolify proxy (`http://localhost:80`).

### Pattern 2: Path-based Routing (Cloudflare Workers)
**What:** Use a Cloudflare Worker to route requests from unified subdomains to specific tenants based on URL paths.
**Example:** `https://chat.nexaduo.com/alpha/` -> backend with `X-Tenant-ID: alpha`.
  zone_id = var.cloudflare_zone_id
  name    = "*"
  content = "${var.tunnel_id}.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
```

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Backup Rotation | Custom cron + rsync | Coolify Backup Retention | Built-in support for S3-compatible rotation (GCS HMAC). |
| SSL Management | Certbot / Let's Encrypt | Cloudflare Edge SSL | Tunnels handle SSL at the edge; internal traffic is unencrypted (HTTP) for simplicity. |
| Ingress Security | Complex IP Whitelisting | Cloudflare Tunnels | "Portless" means zero attack surface for non-authenticated traffic. |

## Common Pitfalls

### Pitfall 1: "Too Many Redirects" Loop
**What goes wrong:** Browser shows ERR_TOO_MANY_REDIRECTS.
**Why it happens:** Cloudflare expects HTTPS, but Coolify/App is trying to redirect HTTP to HTTPS internally, or vice versa.
**How to avoid:** Set Cloudflare SSL to "Full" or "Flexible". In Coolify, configure application domains with `http://` instead of `https://` since the tunnel handles the final leg.

### Pitfall 2: Tunnel Network Isolation
**What goes wrong:** Tunnel connects but returns 502 Bad Gateway.
**Why it happens:** The `cloudflared` container cannot reach the `coolify-proxy` container.
**How to avoid:** Ensure the `cloudflared` container is joined to the `coolify` Docker network.

### Pitfall 3: GCS HMAC Permissions
**What goes wrong:** Backups fail to upload or rotation fails to prune old files.
**Why it happens:** Service account lacks `DeleteObject` or `ListBucket` permissions.
**How to avoid:** Assign `Storage Object Admin` to the HMAC service account for the specific backup bucket.

## Code Examples

### GCS S3-Compatible Endpoint
```text
Endpoint: https://storage.googleapis.com
Region: auto
Access Key: [GCS HMAC Access ID]
Secret Key: [GCS HMAC Secret]
```

### Cloudflare DNS Wildcard (Terraform)
```hcl
resource "cloudflare_record" "wildcard" {
  zone_id = var.cloudflare_zone_id
  name    = "*"
  content = "12345678-abcd-1234-efgh-1234567890ab.cfargotunnel.com"
  type    = "CNAME"
  proxied = true
}
```

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Cloudflare Tunnels support wildcards on non-enterprise plans. | Architecture | High - Would require manual DNS/Tunnel updates for every tenant. |
| A2 | Coolify v4 API/UI allows configuring GCS via S3-interoperability. | Standard Stack | Medium - GCS is standard, but minor UI differences might exist. |

## Open Questions (RESOLVED)

1. **Automation of Tunnel Creation:** Should the Cloudflare Tunnel be created manually in the Zero Trust UI or via Terraform?
   - **Resolution:** Terraform is preferred for consistency. The tunnel and DNS records will be managed via the `cloudflare-tunnel` and `cloudflare-dns` modules. Tokens will be handled as sensitive Terraform variables.
2. **Coolify API Maturity:** Can we fully automate the INFRA-05 (Backup) configuration via API, or should it be a manual "One-time Setup" step?
   - **Resolution:** Initial backup destination setup will be a manual "One-time Setup" step via the Coolify UI to ensure reliable configuration of GCS HMAC credentials.

## SSL and Permissions (RESOLVED)
- **SSL Mode:** Cloudflare SSL/TLS must be set to "Full" or "Full (Strict)" to avoid redirect loops between the edge and the origin.
- **GCS Permissions:** The service account for backups requires `roles/storage.objectAdmin` on the target bucket to perform uploads and automated pruning/rotation.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Terraform | IaC Deployment | ✓ | 1.14.3 | — |
| Docker | Containerization | ✓ | 29.3.1 | — |
| gcloud CLI | GCP Auth | ✓ | 564.0.0 | — |
| Coolify | Orchestration | ✓ | v4 (script) | — |

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V4 Access Control | yes | Cloudflare Zero Trust Access for Dashboard |
| V6 Cryptography | yes | Cloudflare Managed SSL/TLS |
| V12 Network | yes | Portless Ingress (Cloudflare Tunnels) |

### Known Threat Patterns for Cloudflare Tunnels

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Origin Bypass | Information Disclosure | Close all firewall ports except SSH (via IAP). |
| DNS Hijacking | Tampering | Cloudflare DNS SEC & Registrar locking. |

## Sources

### Primary (HIGH confidence)
- Coolify v4 Documentation - [https://coolify.io/docs](https://coolify.io/docs)
- Cloudflare Tunnel Documentation - [https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/](https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/)
- GCP Startup Scripts - [https://cloud.google.com/compute/docs/startupscript](https://cloud.google.com/compute/docs/startupscript)

### Secondary (MEDIUM confidence)
- Community forums on Coolify + Cloudflare Tunnels (verified wildcard support for 2024).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH
- Architecture: HIGH
- Pitfalls: HIGH

**Research date:** 2025-01-24
**Valid until:** 2025-02-24
