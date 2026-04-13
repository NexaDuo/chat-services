#!/bin/bash
# Script de instalação automatizada do Coolify para GCP
set -e

# Define o HOME como /root para evitar o erro 'unbound variable' 
# durante a execução como script de inicialização do GCP.
export HOME=/root

# Força a instalação não interativa via variável de ambiente para automação
export FORCE=true

echo "------------------------------------------"
echo "Iniciando instalação do Coolify (Automated)..."
echo "------------------------------------------"

# Atualização básica do sistema
apt-get update
apt-get upgrade -y

# Instalação do Coolify via script oficial (conforme site oficial)
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | sudo bash

echo "------------------------------------------"
echo "Instalação do Coolify concluída!"
echo "------------------------------------------"
