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
  // Fully random, with NO predictable prefix (issue #135 — the old
  // "NexaDuo@YEAR-" scheme reduced entropy to a guessable pattern). The trailing
  // "Aa1!" only guarantees Chatwoot's required character classes (upper/lower/
  // digit/special); it is not a secret.
  const random = crypto.randomBytes(24).toString('base64').replace(/[^A-Za-z0-9]/g, '');
  return `${random}Aa1!`;
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
