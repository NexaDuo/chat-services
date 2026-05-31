#!/bin/bash
# scripts/setup-local-wsl.sh
# Automates the local WSL2 setup for Docker Desktop and Coolify.
# Disables the native systemd docker service to prevent conflicts and verifies the Docker Desktop integration.

set -e

# Colors for pretty output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0;5m' # No Color
CLEAR='\033[0m'

echo -e "${BLUE}================================================================${CLEAR}"
echo -e "${BLUE}        WSL2 Local Docker Setup for Coolify & NexaDuo           ${CLEAR}"
echo -e "${BLUE}================================================================${CLEAR}"

# 1. Verify WSL environment
if ! grep -q -i microsoft /proc/version; then
    echo -e "${RED}Error: This script is intended to run inside WSL2 (Ubuntu) only.${CLEAR}"
    exit 1
fi
echo -e "${GREEN}[✔] WSL2 environment detected.${CLEAR}"

# 2. Stop and disable native Docker daemon
echo -e "\n${YELLOW}[!] Disabling native systemd Docker service to prevent conflicts...${CLEAR}"
echo -e "You might be prompted for your sudo password."

# Run systemctl commands to stop and disable native docker daemon
sudo systemctl stop docker.service docker.socket || true
sudo systemctl disable docker.service docker.socket || true

echo -e "${GREEN}[✔] Native Docker daemon services stopped and disabled.${CLEAR}"

# 3. Check for Docker Desktop integration
echo -e "\n${YELLOW}[!] Checking Docker Desktop integration socket...${CLEAR}"

SOCKET_PATH="/var/run/docker.sock"

if [ ! -S "$SOCKET_PATH" ]; then
    echo -e "${RED}Error: Docker socket not found at $SOCKET_PATH.${CLEAR}"
    echo -e "${YELLOW}Please ensure that:${CLEAR}"
    echo -e "  1. Docker Desktop is running on Windows."
    echo -e "  2. WSL integration is enabled for this distro in Docker Desktop Settings:"
    echo -e "     Settings > Resources > WSL integration > Enable integration with your distro."
    echo -e "\nAfter enabling it, please re-run this script."
    exit 1
fi

echo -e "${GREEN}[✔] Docker Desktop socket detected at $SOCKET_PATH.${CLEAR}"

# 4. Validate Docker CLI connectivity
echo -e "\n${YELLOW}[!] Verifying Docker CLI connectivity to Docker Desktop...${CLEAR}"

if ! docker ps >/dev/null 2>&1; then
    echo -e "${RED}Error: Docker CLI cannot communicate with the Docker daemon.${CLEAR}"
    echo -e "Please check permissions or verify Docker Desktop status on Windows."
    exit 1
fi

echo -e "${GREEN}[✔] Successfully connected to Docker Desktop engine!${CLEAR}"
echo -e "\nRunning containers on Docker Desktop:"
docker ps --format "table {{.ID}}\t{{.Names}}\t{{.Status}}\t{{.Ports}}"

# 5. Fix permissions (if needed) for lazydocker/user CLI
echo -e "\n${YELLOW}[!] Making sure current user has write permission to the socket...${CLEAR}"
sudo chmod 666 /var/run/docker.sock || true
echo -e "${GREEN}[✔] Permissions fixed.${CLEAR}"

echo -e "\n${GREEN}================================================================${CLEAR}"
echo -e "${GREEN} Setup completed successfully! ${CLEAR}"
echo -e "${GREEN} Coolify and your local CLI tools (like lazydocker) will now use ${CLEAR}"
echo -e "${GREEN} the unified Docker Desktop engine without any conflicts.      ${CLEAR}"
echo -e "${GREEN}================================================================${CLEAR}"
