terraform {
  required_providers {
    coolify = {
      source  = "SierraJC/coolify"
      version = "0.10.2"
    }
  }
}

variable "project_name" {
  type    = string
  default = "Chat Services"
}

variable "server_name" {
  type    = string
  default = "localhost"
}

variable "tunnel_token" {
  type      = string
  sensitive = true
}

# 1. Busca o servidor 'localhost'
data "coolify_server" "main" {
  name = var.server_name
}

# 2. Cria o projeto principal
resource "coolify_project" "main" {
  name = var.project_name
}

# 3. Cria o ambiente de produção dentro do projeto
# Nota: Verifique se o recurso coolify_environment existe na versão do provedor.
# Caso contrário, projetos no Coolify v4 costumam vir com 'production' por padrão.

# 4. Deploy do Cloudflared como um Application/Service
# Vamos usar o modelo de Docker Compose para garantir controle total.
resource "coolify_application" "cloudflared" {
  name         = "cloudflared-tunnel"
  project_uuid = coolify_project.main.uuid
  server_uuid  = data.coolify_server.main.uuid
  
  # Configuração via Docker Compose
  source_type = "docker_compose"
  docker_compose_raw = <<-EOT
    services:
      cloudflared:
        image: cloudflare/cloudflared:latest
        restart: unless-stopped
        command: tunnel --no-autoupdate run
        environment:
          - TUNNEL_TOKEN=$${TUNNEL_TOKEN}
        networks:
          - coolify
    networks:
      coolify:
        external: true
  EOT

  variables = [
    {
      name  = "TUNNEL_TOKEN"
      value = var.tunnel_token
    }
  ]
}
