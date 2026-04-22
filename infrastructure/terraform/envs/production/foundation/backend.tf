terraform {
  backend "gcs" {
    bucket = "nexaduo-terraform-state"
    prefix = "terraform/state/foundation"
  }
}
