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
    default_chatwoot_url?: string;
    default_dify_url?: string;
  };
  tenants: TenantConfig[];
}

function validate() {
  const yamlPath = path.resolve(process.cwd(), 'tenants.yaml');
  const fileContent = fs.readFileSync(yamlPath, 'utf8');
  const config = yaml.parse(fileContent) as TenantsYaml;

  if (!config.global.gcp_project_id || !config.global.base_domain) {
    throw new Error('Global project_id or base_domain missing');
  }

  if (config.global.default_chatwoot_url || config.global.default_dify_url) {
    throw new Error('Deprecated global default URLs must be removed');
  }

  for (const tenant of config.tenants) {
    if (!tenant.environment) {
      throw new Error(`Tenant ${tenant.slug} missing environment field`);
    }
    if (!['production', 'staging'].includes(tenant.environment)) {
      throw new Error(`Tenant ${tenant.slug} has invalid environment: ${tenant.environment}`);
    }
    if (!tenant.infra || !tenant.infra.chatwoot_url || !tenant.infra.dify_url) {
      throw new Error(`Tenant ${tenant.slug} missing explicit infra URLs`);
    }
  }
  console.log('✅ tenants.yaml schema validation passed');
}

validate();
