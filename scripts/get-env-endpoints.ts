import fs from 'fs';
import path from 'path';
import yaml from 'yaml';

interface TenantConfig {
  slug: string;
  name: string;
  chatwoot_account_id: number;
  status: string;
  environment: string;
  infra?: {
    type: string;
    chatwoot_url?: string;
    dify_url?: string;
  };
}

interface TenantsYaml {
  global: {
    gcp_project_id: string;
    base_domain: string;
  };
  tenants: TenantConfig[];
}

function getEndpoints() {
  const yamlPath = path.resolve(process.cwd(), 'tenants.yaml');
  if (!fs.existsSync(yamlPath)) {
    console.error(`Error: tenants.yaml not found`);
    process.exit(1);
  }

  const fileContent = fs.readFileSync(yamlPath, 'utf8');
  const config = yaml.parse(fileContent) as TenantsYaml;

  const targetEnv = process.argv[2] || 'production';
  const filtered = config.tenants.filter(t => t.environment === targetEnv);

  const endpoints = {
    base_domain: config.global.base_domain,
    chatwoot: Array.from(new Set(filtered.map(t => t.infra?.chatwoot_url).filter(Boolean))),
    dify: Array.from(new Set(filtered.map(t => t.infra?.dify_url).filter(Boolean))),
  };

  console.log(JSON.stringify(endpoints, null, 2));
}

getEndpoints();
