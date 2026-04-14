import { Command } from 'commander';
import { z } from 'zod';
import dotenv from 'dotenv';
import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';
import { registerTenantInDb } from './db.js';
import { validateTenantReachability } from './api.js';

dotenv.config();

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TENANTS_JSON_PATH = path.resolve(__dirname, '../tenants.json');

const program = new Command();

const TenantSchema = z.object({
  slug: z.string().regex(/^[a-z0-9-]+$/),
  accountId: z.string(),
});

program
  .name('provision-tenant')
  .description('NexaDuo Provisioning CLI')
  .version('1.0.0');

program
  .command('register-tenant')
  .description('Register a new tenant in the middleware database')
  .requiredOption('--slug <slug>', 'Unique tenant identifier (subdomain)')
  .requiredOption('--account-id <accountId>', 'Chatwoot Account ID')
  .action(async (options) => {
    try {
      // 1. Validate input
      const validated = TenantSchema.parse(options);
      console.log(`Registering tenant: ${validated.slug} with accountId: ${validated.accountId}`);

      // 2. Insert into DB
      await registerTenantInDb(validated.slug, validated.accountId);
      console.log('✓ Successfully registered tenant in database');

      // 3. Update tenants.json
      let tenants = [];
      try {
        const content = await fs.readFile(TENANTS_JSON_PATH, 'utf-8');
        tenants = JSON.parse(content);
      } catch (e) {
        // file might not exist or be empty
      }

      // Add if not already exists, or update
      const index = tenants.findIndex((t: any) => t.slug === validated.slug);
      if (index >= 0) {
        tenants[index] = validated;
      } else {
        tenants.push(validated);
      }

      await fs.writeFile(TENANTS_JSON_PATH, JSON.stringify(tenants, null, 2));
      console.log(`✓ Successfully updated ${TENANTS_JSON_PATH}`);

      // 4. Validate via Middleware API
      console.log('Validating tenant reachability via Middleware...');
      const validation = await validateTenantReachability(validated.slug);
      if (validation && validation.accountId === validated.accountId) {
        console.log('✓ Tenant validated successfully via Middleware API');
      } else {
        console.warn('⚠️ Warning: Tenant registration succeeded but validation via Middleware failed.');
        console.warn('Check if Middleware is running and using the same shared secret.');
      }

    } catch (error) {
      if (error instanceof z.ZodError) {
        console.error('Validation error:', error.issues);
      } else {
        console.error('Error:', error);
      }
      process.exit(1);
    }
  });

program.parse();
