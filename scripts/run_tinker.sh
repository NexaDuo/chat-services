#!/usr/bin/env bash
# scripts/run_tinker.sh
set -euo pipefail

sudo docker exec coolify php artisan tinker --execute="
\$service = App\Models\Service::where('uuid', 'dsgwuwrdnmue9nhdkeovb6tx')->first();
if (\$service) {
    \$service->docker_compose_raw = file_get_contents('/tmp/docker-compose.nexaduo.yml');
    \$service->save();
    echo 'SUCCESS: DB UPDATED';
} else {
    echo 'ERROR: SERVICE NOT FOUND';
}
"
