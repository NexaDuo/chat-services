import { Command } from 'commander';
import { z } from 'zod';
import dotenv from 'dotenv';

dotenv.config();

const program = new Command();

program
  .name('provision-tenant')
  .description('NexaDuo Provisioning CLI')
  .version('1.0.0');

program
  .command('register-tenant')
  .description('Register a new tenant in the middleware database')
  .requiredOption('--slug <slug>', 'Unique tenant identifier (subdomain)')
  .requiredOption('--account-id <accountId>', 'Chatwoot Account ID')
  .action((options) => {
    console.log(`Registering tenant: ${options.slug} with accountId: ${options.accountId}`);
  });

program.parse();
