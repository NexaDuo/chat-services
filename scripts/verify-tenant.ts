import axios from 'axios';
import fs from 'fs/promises';
import path from 'path';
import { fileURLToPath } from 'url';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const TENANTS_JSON_PATH = path.resolve(__dirname, '../provisioning/tenants.json');

async function verifyTenant(slug: string, baseUrl: string) {
  console.log(`Verifying tenant [${slug}] at ${baseUrl}/${slug}/`);
  
  try {
    // 1. Verify path reachability
    const response = await axios.get(`${baseUrl}/${slug}/`, {
      timeout: 5000,
      validateStatus: () => true // Don't throw on any status
    });

    console.log(`- Status: ${response.status}`);
    
    if (response.status === 200) {
      console.log('✓ Success: Path is reachable');
      
      // 2. Check for HTMLRewriter injection (heuristic)
      const html = response.data;
      if (typeof html === 'string' && html.includes(`/${slug}/`)) {
        console.log('✓ Success: HTMLRewriter appears to be working (prefixed paths found)');
      } else {
        console.warn('⚠️ Warning: Could not verify HTMLRewriter injection in the response body.');
      }
    } else {
      console.error(`✖ Failed: Expected status 200, got ${response.status}`);
    }

  } catch (error: any) {
    console.error(`✖ Failed: Could not connect to tenant path: ${error.message}`);
  }
}

async function main() {
  const args = process.argv.slice(2);
  const targetSlug = args[0];
  const baseUrl = args[1] || 'https://chat.nexaduo.com';

  if (targetSlug) {
    await verifyTenant(targetSlug, baseUrl);
  } else {
    // Verify all from tenants.json
    try {
      const content = await fs.readFile(TENANTS_JSON_PATH, 'utf-8');
      const tenants = JSON.parse(content);
      console.log(`Verifying ${tenants.length} tenants...`);
      for (const tenant of tenants) {
        await verifyTenant(tenant.slug, baseUrl);
      }
    } catch (e) {
      console.error('Error reading tenants.json or no tenants found.');
    }
  }
}

main();
