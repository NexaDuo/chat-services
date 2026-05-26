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

# Wait and mount persistent postgres disk if attached
DISK_ID="/dev/disk/by-id/google-postgres-disk"
MOUNT_PATH="/opt/nexaduo/postgres-data"

if [ -b "$DISK_ID" ]; then
  echo "Mounting persistent disk: $DISK_ID"
  
  # Format ext4 if partition is unformatted
  if ! blkid "$DISK_ID" > /dev/null 2>&1; then
    mkfs.ext4 -m 0 -E lazy_itable_init=0,lazy_journal_init=0,discard "$DISK_ID"
  fi
  
  # Create directory and mount
  mkdir -p "$MOUNT_PATH"
  mount -o discard,defaults "$DISK_ID" "$MOUNT_PATH"
  
  # Set permissions so postgres can write
  chown -R 999:999 "$MOUNT_PATH"
  chmod -R 775 "$MOUNT_PATH"
  
  # Persist mount across reboots
  if ! grep -q "$DISK_ID" /etc/fstab; then
    echo "$DISK_ID $MOUNT_PATH ext4 discard,defaults,nofail 0 2" >> /etc/fstab
  fi
fi
