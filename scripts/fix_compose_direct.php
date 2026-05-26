<?php
// fix_compose_direct.php
$uuid = $argv[1];
$compose = file_get_contents('/tmp/docker-compose.nexaduo.yml');

$service = App\Models\Service::where('uuid', $uuid)->first();
if ($service) {
    $service->docker_compose_raw = $compose;
    $service->save();
    echo "SUCCESS: $uuid\n";
} else {
    echo "ERROR: Service not found: $uuid\n";
    exit(1);
}
