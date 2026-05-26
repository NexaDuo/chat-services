# Design Spec: Staging Environment

## Purpose
Provision separate staging infrastructure on dedicated VM.
Isolate staging and production configuration in tenants.yaml.

## tenants.yaml Schema
```yaml
global:
  gcp_project_id: "nexaduo-492818"
  base_domain: "nexaduo.com"

tenants:
  - slug: nexaduo
    environment: production
    infra:
      type: shared
      chatwoot_url: "https://chat.nexaduo.com"
      dify_url: "https://dify.nexaduo.com"

  - slug: acme-stg
    environment: staging
    infra:
      type: shared
      chatwoot_url: "https://chat-stg.nexaduo.com"
      dify_url: "https://dify-stg.nexaduo.com"
```

## Infrastructure Changes
1. Provision separate staging VM using Terraform.
2. Configure DNS routing for staging subdomains.
3. Map domains chat-stg.nexaduo.com and dify-stg.nexaduo.com.

## Sync Script Logic
1. Parse environment parameter from command line or environment variables.
2. Select target database URL based on environment.
3. Synchronize only matching tenants (production or staging).
4. Extract explicit URLs from tenant infra configurations.

## Testing Strategy
1. Verify tenants.yaml parsing with typescript.
2. Test sync script with staging database locally.
3. Deploy to staging VM and verify endpoints.
