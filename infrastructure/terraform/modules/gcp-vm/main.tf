terraform {
  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 5.0"
    }
  }
}

variable "project_id" {
  type = string
}

variable "region" {
  type    = string
  default = "us-central1"
}

variable "zone" {
  type    = string
  default = "us-central1-a"
}

variable "name" {
  type    = string
  default = "nexaduo-chat-services"
}

variable "machine_type" {
  type    = string
  default = "e2-standard-4"
}

variable "disk_size" {
  type    = number
  default = 50
}

variable "boot_disk_type" {
  type    = string
  default = "pd-balanced"
}

variable "postgres_disk_type" {
  type    = string
  default = "pd-balanced"
}

variable "ssh_user" {
  type    = string
  default = "ubuntu"
}

variable "ssh_key" {
  type = string
}

variable "service_account_email" {
  description = "Service account attached to the VM. Defaults to the project's default Compute SA, which receives Artifact Registry reader access in the foundation layer."
  type        = string
  default     = null
}

resource "google_compute_network" "vpc" {
  name                    = "${var.name}-vpc"
  auto_create_subnetworks = false
}

resource "google_compute_subnetwork" "subnet" {
  name          = "${var.name}-subnet"
  region        = var.region
  network       = google_compute_network.vpc.id
  ip_cidr_range = "10.0.1.0/24"
}

resource "google_compute_address" "static_ip" {
  name   = "${var.name}-ip"
  region = var.region
}

resource "google_compute_firewall" "allow_ssh_iap" {
  name    = "${var.name}-allow-ssh-iap"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["22"]
  }

  source_ranges = ["35.235.240.0/20"] # Google IAP range
}

data "http" "cloudflare_ips" {
  url = "https://api.cloudflare.com/client/v4/ips"
}

resource "google_compute_firewall" "allow_cloudflare" {
  name    = "${var.name}-allow-cloudflare"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["80", "443"]
  }

  source_ranges = jsondecode(data.http.cloudflare_ips.response_body).result.ipv4_cidrs
}

resource "google_compute_firewall" "allow_coolify" {
  name    = "${var.name}-allow-coolify"
  network = google_compute_network.vpc.name

  allow {
    protocol = "tcp"
    ports    = ["8000", "6001"]
  }

  source_ranges = ["0.0.0.0/0"] # Temporary for setup; can be restricted later
}

resource "google_compute_instance" "vm" {
  name                      = var.name
  machine_type              = var.machine_type
  zone                      = var.zone
  allow_stopping_for_update = true

  boot_disk {
    initialize_params {
      image = "ubuntu-os-cloud/ubuntu-2404-lts-amd64"
      size  = var.disk_size
      type  = var.boot_disk_type
    }
  }

  # Dedicated Postgres data disk, attached inline so it is managed atomically
  # with the instance. The previous standalone google_compute_attached_disk
  # resource detached the disk on every apply, corrupting the ext4 filesystem
  # and the Postgres data dir (observed on both staging and production).
  attached_disk {
    source      = google_compute_disk.postgres_disk.id
    device_name = "postgres-disk"
    mode        = "READ_WRITE"
    # The data disk is a separate resource guarded by prevent_destroy; a
    # secondary attached_disk is never auto-deleted on instance delete/recreate,
    # so the volume survives a VM replacement (it reattaches by source id).
  }

  network_interface {
    subnetwork = google_compute_subnetwork.subnet.id
    access_config {
      nat_ip = google_compute_address.static_ip.address
    }
  }

  metadata = {
    ssh-keys = "${var.ssh_user}:${var.ssh_key}"
  }

  metadata_startup_script = file("${path.module}/scripts/install-coolify.sh")

  tags = ["ssh-iap"]

  service_account {
    email  = var.service_account_email
    scopes = ["cloud-platform"]
  }
}

output "public_ip" {
  value = google_compute_address.static_ip.address
}

# Daily disk-level snapshots (14-day retention) as a second line of defense for
# the Postgres volume, beyond the pg_dump-to-GCS cron. Kept even if the disk is
# deleted, so a recreate/mkfs is recoverable.
resource "google_compute_resource_policy" "postgres_snapshot" {
  name   = "${var.name}-postgres-snapshot"
  region = var.region

  snapshot_schedule_policy {
    schedule {
      daily_schedule {
        days_in_cycle = 1
        start_time    = "06:00"
      }
    }
    retention_policy {
      max_retention_days    = 14
      on_source_disk_delete = "KEEP_AUTO_SNAPSHOTS"
    }
    snapshot_properties {
      storage_locations = [var.region]
    }
  }
}

resource "google_compute_disk" "postgres_disk" {
  name = "${var.name}-postgres-disk"
  type = var.postgres_disk_type
  zone = var.zone
  size = var.disk_size

  resource_policies = [google_compute_resource_policy.postgres_snapshot.id]

  # The Postgres data disk is sacred. A change to a force-new attribute — e.g.
  # `type` (exactly the 2026-06-25 pd-balanced change that recreated this disk
  # blank and wiped production) — would otherwise silently destroy it.
  # prevent_destroy turns any such plan into a hard ERROR instead of data loss;
  # ignore_changes[type] stops disk-type drift from ever planning a replacement.
  # See memory: prod-data-loss-2026-06-25.
  lifecycle {
    prevent_destroy = true
    ignore_changes  = [type]
  }
}

