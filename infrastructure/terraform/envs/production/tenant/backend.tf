terraform {
  backend "gcs" {
    bucket = "nexaduo-terraform-state"
    prefix = "terraform/state/production/tenant"
  }
}
