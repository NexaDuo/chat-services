data "google_secret_manager_secret_version" "cloudflare_api_token" {
  secret = "cloudflare_api_token"
}
