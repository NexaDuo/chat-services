#!/bin/bash
# Script de instalação automatizada do Coolify para GCP
set -e

# Define o HOME como /root para evitar o erro 'unbound variable' 
# durante a execução como script de inicialização do GCP.
export HOME=/root

echo "------------------------------------------"
echo "Iniciando instalação do Coolify (Automated)..."
echo "------------------------------------------"

# Atualização básica do sistema
apt-get update
apt-get upgrade -y

# Instalação do Coolify via script oficial com a flag --force
# A flag --force ignora todos os prompts interativos (Y/N)
curl -fsSL https://cdn.coollabs.io/coolify/install.sh | bash -s -- --force

echo "------------------------------------------"
echo "Instalação do Coolify concluída!"
echo "------------------------------------------"
