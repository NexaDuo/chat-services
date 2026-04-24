import { execSync } from 'child_process';
import fs from 'fs';
import path from 'path';
import dotenv from 'dotenv';

dotenv.config();

const BACKUP_DIR = process.env.BACKUP_DIR || './backups';
const KEEP_DAYS = parseInt(process.env.BACKUP_KEEP_DAYS || '14', 10);
const POSTGRES_USER = process.env.POSTGRES_USER || 'postgres';
const GCS_BUCKET = process.env.BACKUP_GCS_BUCKET;

const timestamp = new Date().toISOString().replace(/[:.]/g, '-').slice(0, 16);
const databases = ['chatwoot', 'dify', 'dify_plugin', 'evolution'];

if (!fs.existsSync(BACKUP_DIR)) {
  fs.mkdirSync(BACKUP_DIR, { recursive: true });
}

console.log(`Starting backup at ${new Date().toISOString()}`);

for (const db of databases) {
  const outFile = path.join(BACKUP_DIR, `${db}-${timestamp}.sql.gz`);
  console.log(`==> Dumping ${db} to ${outFile}`);
  
  try {
    // Executando dump via docker e comprimindo
    execSync(`docker compose exec -T postgres pg_dump -U ${POSTGRES_USER} -d ${db} --no-owner --clean --if-exists | gzip -9 > ${outFile}`);
  } catch (error) {
    console.error(`Failed to backup database ${db}:`, error);
  }
}

// Rotação de backups
console.log(`==> Cleaning backups older than ${KEEP_DAYS} days`);
const files = fs.readdirSync(BACKUP_DIR);
const now = Date.now();
files.forEach(file => {
  const filePath = path.join(BACKUP_DIR, file);
  const stats = fs.statSync(filePath);
  const ageDays = (now - stats.mtimeMs) / (1000 * 60 * 60 * 24);
  
  if (ageDays > KEEP_DAYS && file.endsWith('.sql.gz')) {
    console.log(`  - Deleting ${file}`);
    fs.unlinkSync(filePath);
  }
});

// Sincronização GCS
if (GCS_BUCKET) {
  console.log(`==> Syncing with GCS: gs://${GCS_BUCKET}`);
  try {
    execSync(`gsutil -m rsync -r -d ${BACKUP_DIR} gs://${GCS_BUCKET}`);
  } catch (error) {
    console.error('GCS Sync failed:', error);
  }
}

console.log('Backup process completed.');
