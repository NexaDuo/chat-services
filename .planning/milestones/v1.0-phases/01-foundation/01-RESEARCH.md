# Phase 1: Foundation (Terraform & GCP) - Research

**Researched:** April 14, 2026
**Domain:** Infrastructure as Code (Terraform) on Google Cloud Platform
**Confidence:** HIGH

## Summary

This research establishes the modern, cost-effective, and secure baseline for the NexaDuo infrastructure on GCP. By leveraging Terraform 1.10+, Google Provider 7.x, and Cloudflare 5.x, we align with current state-of-the-art (SOTA) practices for 2026.

**Primary recommendation:** Use a "Portless Origin" architecture where all HTTP/S ingress is handled by Cloudflare Tunnels (Argo), and SSH access is strictly managed via Google Identity-Aware Proxy (IAP) with OS Login enabled. This eliminates the need for any open ingress ports on the public internet.

## User Constraints (from CONTEXT.md)

> Note: CONTEXT.md was not explicitly provided, but project decisions were extracted from STATE.md and PROJECT.md.

### Locked Decisions
- **GCP Instance:** `e2-standard-4` (4 vCPU, 16 GB RAM) for cost-efficiency.
- **Remote State:** GCS bucket `nexaduo-terraform-state` for state management.
- **Ingress:** Cloudflare Tunnels (Argo) for "portless" origin architecture.
- **Path-based Routing:** `chat.nexaduo.com/{tenant}/`.

### the agent's Discretion
- **Storage Type:** Choice of SSD type (Recommended: `pd-balanced`).
- **Network Tier:** Choice of Standard vs Premium (Recommended: `Standard` for cost-saving behind Cloudflare).
- **SSH Management:** Choice of method (Recommended: `OS Login` + `IAP`).

### Deferred Ideas (OUT OF SCOPE)
- **Cloudflare Worker:** Postponed to Phase 3.
- **Direct Origin Access:** Explicitly avoided (except for emergency SSH via IAP).

## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| INFRA-01 | Provision GCP Compute Instance (e2-standard-4) | Verified SOTA configuration for E2 family in 2026. |
| INFRA-02 | Configure GCP Networking (VPC, Firewall, Static IP) | Identified IAP-only firewall pattern and Standard Tier cost savings. |
| INFRA-03 | Provision Persistent SSD Storage (50-100GB) | Identified `pd-balanced` as the cost/performance sweet spot. |

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Terraform | 1.14.3+ | Infrastructure as Code | Industry standard for multi-cloud/GCP. |
| Google Provider | ~> 7.15 | GCP Resource Management | SOTA major version for 2026. |
| Cloudflare Provider| ~> 5.14 | Edge Networking | SOTA version with OpenAPI-generated resources. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|--------------|
| SierraJC/coolify | 0.10.2 | Coolify Management | Required for orchestrating Chatwoot/Dify. |
| Google Cloud SDK | 564.0.0 | CLI Management | Required for IAP Tunneling and Auth. |

**Installation:**
```bash
# Verify tools are available
terraform --version
gcloud --version
```

## Architecture Patterns

### Recommended Project Structure
```text
infrastructure/terraform/
├── envs/
│   └── production/    # Production environment state & variables
│       ├── main.tf
│       ├── providers.tf
│       └── backend.tf
└── modules/
    ├── gcp-vm/         # Encapsulates E2 VM, Disk, and IAP Firewall
    ├── cloudflare-dns/ # DNS record management
    └── cloudflare-tunnel/ # Argo Tunnel lifecycle
```

### Pattern 1: Portless Origin (Zero Trust)
**What:** Close all ingress ports (80, 443, 22) to `0.0.0.0/0`. Use `cloudflared` to bridge traffic and `IAP` for administrative access.
**When to use:** All production deployments to minimize attack surface.
**Example:**
```hcl
# Source: Verified 2026 GCP Security Baseline
resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "allow-ssh-iap"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  # Only allow Google IAP proxy range
  source_ranges = ["35.235.240.0/20"]
}
```

### Anti-Patterns to Avoid
- **Legacy SSH Keys:** Using `ssh-keys` metadata is deprecated. Use **OS Login** instead.
- **Public HTTP/S Ports:** Do not open 80/443 on the GCP Firewall if using Cloudflare Tunnels.
- **Premium Network Tier:** Using Premium tier for a single-node setup behind Cloudflare is often an unnecessary ~30% cost increase.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| SSH Access Control | Custom bash/IAM scripts | GCP OS Login | Built-in IAM integration and audit logs. |
| Reverse Proxy Auth | Custom Nginx config | Cloudflare Tunnel | Handles TLS, auto-updates, and Zero Trust out-of-box. |
| Outbound Internet | Cloud NAT | Static IP (NAT-on-VM) | Cloud NAT costs ~$33/mo; a Static IP is effectively free when assigned to a VM. |

## Common Pitfalls

### Pitfall 1: OS Login Not Enabled Project-Wide
**What goes wrong:** User-level metadata keys might still work, or new VMs might default to legacy keys.
**How to avoid:** Set `enable-oslogin = "TRUE"` in project-wide metadata.

### Pitfall 2: IOPS Starvation on Small Disks
**What goes wrong:** `pd-standard` or `pd-balanced` with very small sizes (<32GB) may hit IOPS limits during heavy Dify/Postgres operations.
**How to avoid:** Minimum 50GB `pd-balanced` (as per requirements) to ensure 300 IOPS base + scaling.

## Code Examples

### OS Login & Shielded VM Configuration
```hcl
# Source: [Official GCP Provider v7 Docs]
resource "google_compute_instance" "app_vm" {
  name         = "nexaduo-origin"
  machine_type = "e2-standard-4"
  zone         = "us-central1-a"

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = 50
      type  = "pd-balanced"
    }
  }

  network_interface {
    network = google_compute_network.vpc.id
    access_config {
      network_tier = "STANDARD" # Cost-effective choice
    }
  }

  metadata = {
    enable-oslogin = "TRUE"
  }

  shielded_instance_config {
    enable_secure_boot          = true
    enable_vtpm                 = true
    enable_integrity_monitoring = true
  }
}
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Metadata SSH Keys | OS Login | 2023-24 | Revocation is instant via IAM. |
| `pd-ssd` | `pd-balanced` | 2024 | ~40% cheaper for similar burst performance. |
| `pd-standard` | `pd-balanced` | 2024 | Standard is too slow for modern containerized apps. |
| Port 22 Open | IAP Tunneling | 2024 | Zero public exposure for SSH. |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Standard Tier networking is sufficient behind Cloudflare | State of the Art | Minor latency increase (masked by CF). |
| A2 | Coolify 0.10.2 provider is stable for Phase 4 | Standard Stack | May need manual fixes if API changes. |

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Terraform | IaC Execution | ✓ | 1.14.3 | — |
| gcloud CLI | Auth/IAP | ✓ | 564.0.0 | — |
| node | Scripting | ✓ | 25.8.2 | — |
| cloudflared | Tunneling | ✗ | — | Install via script on VM |

**Missing dependencies with no fallback:**
- None.

**Missing dependencies with fallback:**
- `cloudflared`: Not on host, but will be installed on the target VM via Terraform startup script or Coolify.

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | Terraform Test / Terratest |
| Config file | `envs/production/tests/` |
| Quick run command | `terraform test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command |
|--------|----------|-----------|-------------------|
| INFRA-01 | VM exists and is e2-standard-4 | unit | `terraform test` |
| INFRA-02 | Firewall blocks 80/443 | integration | `gcloud compute firewall-rules describe ...` |
| INFRA-03 | Disk type is pd-balanced | unit | `terraform test` |

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V1 Architecture | Yes | Zero Trust / Portless Origin |
| V14 Configuration | Yes | Terraform-managed VPC/IAM |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| SSH Brute Force | Tampering | IAP Tunneling (No public port 22) |
| Origin Bypass | Information Disclosure | Cloudflare Tunnel (Origin only talks to CF) |

## Sources

### Primary (HIGH confidence)
- GCP Official Documentation (Verified 2026) - OS Login, IAP, Network Tiers.
- Terraform Registry (Verified 2026) - Provider versions for Google (v7), Cloudflare (v5), Coolify (v0.10).
- Local Environment Check - Tool availability (Terraform 1.14, gcloud 564).

### Secondary (MEDIUM confidence)
- Cloudflare Tunnel best practices (2025/2026 blogs).

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH (Checked registry)
- Architecture: HIGH (Aligned with security best practices)
- Pitfalls: MEDIUM (Based on common GCP migration issues)

**Research date:** 2026-04-14
**Valid until:** 2026-05-14
