<?php
// fix_compose.php
require_once __DIR__ . '/vendor/autoload.php';
$app = require_once __DIR__ . '/bootstrap/app.php';
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();

$uuid = $argv[1];
$compose = stream_get_contents(STDIN);

$service = App\Models\Service::where('uuid', $uuid)->first();
if ($service) {
    $service->docker_compose_raw = $compose;
    $service->save();
    echo "SUCCESS: $uuid\n";
} else {
    echo "ERROR: Service not found: $uuid\n";
    exit(1);
}
