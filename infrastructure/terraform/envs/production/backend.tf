terraform {
  backend "gcs" {
    # Recomenda-se passar o bucket via -backend-config no terraform init
    # ou preencher aqui se o bucket já existir.
    # bucket = "seu-bucket-terraform-state"
    # prefix = "terraform/state"
  }
}
