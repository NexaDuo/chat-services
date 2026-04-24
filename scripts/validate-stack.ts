import { execSync } from 'child_process';
import path from 'path';

const ROOT = path.resolve(__dirname, '..');

const run = (cmd: string, cwd: string = ROOT) => {
  console.log(`==> Executing: ${cmd}`);
  execSync(cmd, { cwd, stdio: 'inherit' });
};

try {
  console.log('--- NexaDuo Stack Validation (TS) ---');

  // 1. Clean Slate
  run('docker compose down -v');

  // 2. Network ensure
  try {
    run('docker network create nexaduo-network');
  } catch (e) {
    // Ignore if already exists
  }

  // 3. Bring Up
  run('docker compose up -d');

  // 3b. Manual Wait for core services (Healthcheck)
  console.log('==> Waiting for containers to stabilize...');
  const waitCmd = `
    i=1;
    while [ $i -le 60 ]; do
      if curl -s -L http://localhost:3000 > /dev/null && curl -s -L http://localhost:5001/console/api/setup > /dev/null; then
        echo "Services are up!"
        exit 0
      fi
      echo "Waiting... ($i/60)"
      sleep 5
      i=$((i+1))
    done
    echo "Timeout waiting for services"
    exit 1
  `;
  run(waitCmd);

  // 4. Run Playwright Infrastructure Stage
  console.log('==> Waiting for services to be healthy...');
  run('npx playwright test tests/01-infra.spec.ts', path.join(ROOT, 'onboarding'));

  // 5. Run Playwright Onboarding Stage
  run('npx playwright test tests/02-setup.spec.ts', path.join(ROOT, 'onboarding'));

  // 6. Run Playwright Smoke Stage
  run('npx playwright test tests/03-smoke.spec.ts', path.join(ROOT, 'onboarding'));

  console.log('OK: Stack validated successfully.');
} catch (error) {
  console.error('FAIL: Stack validation failed.');
  process.exit(1);
}
