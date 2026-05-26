#!/usr/bin/env bash
# scripts/fix_compose_vm.sh
set -euo pipefail

sudo docker cp /tmp/fix_compose.php coolify:/var/www/html/fix_compose.php
sudo docker exec -i coolify php /var/www/html/fix_compose.php dsgwuwrdnmue9nhdkeovb6tx < /tmp/docker-compose.nexaduo.yml
echo "Coolify DB updated successfully for nexaduo service."
