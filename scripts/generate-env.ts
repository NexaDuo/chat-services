import fs from 'fs';
import path from 'path';
import crypto from 'crypto';

const ROOT = path.resolve(__dirname, '..');
const ENV_PATH = path.join(ROOT, '.env');
const EXAMPLE_PATH = path.join(ROOT, '.env.example');

const force = process.argv.includes('-f');

if (fs.existsSync(ENV_PATH) && !force) {
  console.log('.env already exists. Use -f to force overwrite.');
  process.exit(0);
}

const generateSecret = (bytes: number) => crypto.randomBytes(bytes).toString('hex');

const generateRobustPassword = () => {
  const hex = crypto.randomBytes(4).toString('hex').toUpperCase();
  return `NexaDuo@2026-${hex}`;
};

console.log('Generating .env from .env.example...');

let content = fs.readFileSync(EXAMPLE_PATH, 'utf-8');

// Substituições básicas
content = content.replace(/\${secret_hex_16}/g, generateSecret(16));
content = content.replace(/\${secret_hex_32}/g, generateSecret(32));
content = content.replace(/\${secret_hex_64}/g, generateSecret(64));

// Senha Robusta para Admin
const robustPassword = generateRobustPassword();
content = content.replace(/^ADMIN_PASSWORD=.*/m, `ADMIN_PASSWORD=${robustPassword}`);

fs.writeFileSync(ENV_PATH, content);

console.log('.env generated successfully with robust secrets.');
