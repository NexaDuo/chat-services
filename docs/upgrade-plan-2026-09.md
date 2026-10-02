> Plano gerado pelo Codex (planejamento read-only) em 2026-09-27, revisado pelo `@techlead`. Épico: #219. Versões/links refletem a consulta dessa data — revalidar por onda.

# Plano de atualização — Multitenant Chat Services

Data da consulta: **27/09/2026**. Planejamento somente; nenhum Docker, teste, deploy, commit ou push foi executado. AGENTS.md foi lido primeiro. O host único é produção; CI efêmera não é staging. Caminhos abaixo são relativos à raiz do repositório.

**Decisão:** atualizar em PRs sequenciais, preservar contratos e dados, substituir Promtail por Alloy e deixar PostgreSQL major para uma janela própria, opcional. “Última estável” não equivale a “troca segura de tag”. **ASSUMED** identifica informação não comprovada ou condição que impede liberar a onda.

## 1. Inventário reproduzível

Legenda: **T** = tag de versão explícita, ainda mutável; **F** = flutuante (latest, major/minor ou intervalo); **V** = variável, valor efetivo não inspecionado; **D** = digest/hash. Não li `.env`, estados Terraform nem segredos. Pins do código não provam versões em execução.

### Imagens e runtimes

| Arquivo:linha | Referência atual | Tipo |
|---|---|---|
| `deploy/docker-compose.chatwoot.yml:34,72,133` | `chatwoot/chatwoot:v4.18.0-ce@sha256:faaa58a9…` (W8; antes v4.13.0-ce) | D |
| `deploy/docker-compose.dify.yml:32` | `alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6` | D (W6b) |
| `deploy/docker-compose.dify.yml:43,124` | `langgenius/dify-api:1.17.1@sha256:ceede5b9…` (W7b; antes 1.13.3) | D |
| `deploy/docker-compose.dify.yml:180` | `langgenius/dify-web:1.17.1@sha256:6353fe8e…` (W7b; antes 1.13.3) | D |
| `deploy/docker-compose.dify.yml:217` | `langgenius/dify-sandbox:0.2.15@sha256:750e1111…` (W7b; antes 0.2.14) | D |
| `deploy/docker-compose.dify.yml:236` | `langgenius/dify-plugin-daemon:0.6.10-local@sha256:34412a22…` (W7b; antes 0.5.3-local) | D |
| `deploy/docker-compose.dify.yml:268` | `nexaduo/squid:7.7-local`, build local de `deploy/squid/Dockerfile` (W7a; antes `ubuntu/squid`) | D (tarball por SHA-256 + assinatura, base por digest) |
| `deploy/docker-compose.localproxy.yml:61` | `traefik:v3.6.25` | T |
| `deploy/docker-compose.nexaduo.yml:16` | `evoapicloud/evolution-api:v2.3.7@sha256:1bd8afc4a6cf48822e6cf02469aeae7bd35a12a6b616eacd1291926307f4d339` (W6; prior inventory: 2.1.1) | D |
| `deploy/docker-compose.nexaduo.yml:54` | `${MIDDLEWARE_IMAGE}` | V |
| `deploy/docker-compose.nexaduo.yml:94` | `grafana/loki:3.2.0` | T |
| `deploy/docker-compose.nexaduo.yml:126` | `grafana/promtail:3.1.0` | T |
| `deploy/docker-compose.nexaduo.yml:161` | `grafana/grafana:11.6.16` | T |
| `deploy/docker-compose.nexaduo.yml:205` | `prom/prometheus:v2.55.0` | T |
| `deploy/docker-compose.nexaduo.yml:232` | `${SELF_HEALING_IMAGE}` | V |
| `deploy/docker-compose.nexaduo.yml:257` | `otel/opentelemetry-collector-contrib:0.111.0` | T |
| `deploy/docker-compose.nexaduo.yml:283` | `grafana/tempo:2.6.1` | T |
| `deploy/docker-compose.shared.yml:55` | `pgvector/pgvector:pg16` | F |
| `deploy/docker-compose.shared.yml:90` | `redis:8.10.2-alpine@sha256:38117873…` (W5b; antes 7.2.16-alpine) | D |
| `deploy/docker-compose.shared.yml:151` | `cloudflare/cloudflared:latest` | F |
| `deploy/docker-compose.shared.yml:201` | `willfarrell/autoheal:1.2.0` | T |
| `middleware/Dockerfile:8,15,24,31` | `node:24.21.0-alpine3.24@sha256:ebfe2f90…` (W9; antes node:22-alpine) | D |
| `agents/self-healing/Dockerfile:1,9` | `node:24.21.0-alpine3.24@sha256:ebfe2f90…` (W9; antes node:20-alpine) | D |
| `scripts/backup-host.sh:56` | `BACKUP_HELPER_IMAGE=alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6` | D (W6b) |
| `scripts/tests/test-tempo.sh:9`, `scripts/tests/test-otel-collector.sh:31` | `alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6` | D (W6b) |
| `.env.production.example:112,113` | `ghcr.io/nexaduo/{middleware,self-healing-agent}:latest` | F, exemplos |
| `.env.example:176,177` | `ghcr.io/nexaduo/{middleware,self-healing-agent}:0.1.0` | T, exemplos; não runtime |
| `.github/workflows/stack-compose-playwright.yml:99,100` | `ghcr.io/nexaduo/{middleware,self-healing-agent}:latest` | F, builds locais de CI |
| `infrastructure/terraform/modules/coolify-management/main.tf:51` | `cloudflare/cloudflared:latest` | F, template legado |
| `middleware/package.json:16,17` | Node `>=22.0.0` | F, sem teto; demais cinco manifests sem engines |

`docker-compose.yml`, `deploy/docker-compose.ci.yml` e `deploy/docker-compose.isolated.yml` não acrescentam pins de imagem. O root sobrescreve o bind legado de PostgreSQL pelo volume nomeado (`docker-compose.yml:136`); preservar a cadeia completa. Os seis manifests têm versões próprias de app (root/provisioning/onboarding/self-healing `1.0.0`, middleware `0.1.0`; edge sem versão), sem correspondência garantida com imagens publicadas.

### CI: todas as ocorrências, agrupadas por pin

Prefixo dos caminhos desta tabela: `.github/workflows/`. Actions por `@vN` são **F**, não commits imutáveis; o workflow reutilizado local acompanha o commit do chamador.

| Pin atual | Arquivo:linhas | Última release / alvo proposto |
|---|---|---|
| `1.9.8` | `deploy.yml:66` | Terraform 1.16.4; manter legado desligado |
| `ubuntu-latest` | `deploy.yml:83,173,251,317,391,529,574,746,782,910`; `power.yml:44`; `publish-images.yml:34`; `stack-compose-playwright.yml:14,30`; `unit-tests.yml:27,55`; `validate-tenants.yml:19` | GA 26.04; alvo inicial ubuntu-24.04, W0b → ubuntu-26.04 |
| `actions/checkout@v4` | `deploy.yml:93,179,320,397,532,577,749,789`; `power.yml:47`; `publish-images.yml:44`; `stack-compose-playwright.yml:18,64`; `unit-tests.yml:31,59`; `validate-tenants.yml:21` | v7.0.1 |
| `google-github-actions/auth@v2` | `deploy.yml:182,254,322,401,534,580,751,819,913`; `power.yml:49`; `publish-images.yml:47` | v3 |
| `google-github-actions/setup-gcloud@v2` | `deploy.yml:187,259,327,406,539,585,756,824,918`; `power.yml:54`; `publish-images.yml:52` | v3.0.1 |
| `hashicorp/setup-terraform@v3` | `deploy.yml:189,329,414` | v4.0.1 |
| `./.github/workflows/publish-images.yml` | `deploy.yml:375` | mesmo commit; legado, não acionar |
| `actions/setup-node@v4` | `deploy.yml:593,837`; `stack-compose-playwright.yml:67`; `unit-tests.yml:40,65`; `validate-tenants.yml:22` | v7.0.0 |
| `22` | `deploy.yml:595,839`; `stack-compose-playwright.yml:69`; `unit-tests.yml:42,67`; `validate-tenants.yml:24` | Node 24.21.0 LTS (Current 26.10.0 não escolhido) |
| `actions/upload-artifact@v4` | `deploy.yml:891` | v7.0.1 |
| `docker/setup-buildx-action@v3` | `publish-images.yml:57` | v4.4.1 |
| `docker/metadata-action@v5` | `publish-images.yml:60` | v6.2.0 |
| `docker/build-push-action@v6` | `publish-images.yml:69` | v7.4.0 |
| `8.21.2` | `stack-compose-playwright.yml:22` | Gitleaks 8.30.1 |

Fontes das actions: releases oficiais de [checkout](https://github.com/actions/checkout/releases), [setup-node](https://github.com/actions/setup-node/releases), [upload-artifact](https://github.com/actions/upload-artifact/releases), [Buildx](https://github.com/docker/setup-buildx-action/releases), [metadata](https://github.com/docker/metadata-action/releases), [build-push](https://github.com/docker/build-push-action/releases), [auth](https://github.com/google-github-actions/auth/releases), [gcloud](https://github.com/google-github-actions/setup-gcloud/releases), [setup-terraform](https://github.com/hashicorp/setup-terraform/releases), [Gitleaks](https://github.com/gitleaks/gitleaks/releases/tag/v8.30.1). O `auth@v3` é explicitamente um tag flutuante: resolver commit na implementação. [Runners](https://github.com/actions/runner-images) oferecem 26.04 GA; labels de SO continuam recebendo atualizações e não fixam uma VM exata.

### Terraform e configurações de formato

Abreviação `TF` = `infrastructure/terraform`; `P` = `TF/envs/production`. Versões nos locks são exatas, com hashes de pacotes; constraints `~>` continuam flutuantes dentro da major. Não há `required_version` nos `.tf` examinados.

| Componente | Localização e pin atual | Última estável / decisão |
|---|---|---|
| Cloudflare | `TF/modules/{cloudflare-dns,cloudflare-tunnel}/main.tf:5`, `P/foundation/providers.tf:9`: `~>4.0`; `P/.terraform.lock.hcl:5`, `P/foundation/.terraform.lock.hcl:5`: `4.52.7` | [5.26.0](https://github.com/cloudflare/terraform-provider-cloudflare/releases/tag/v5.26.0); migração de HCL + state, W12 |
| Google | `TF/modules/{gcp-vm,gcp-storage}/main.tf:5`, `P/{foundation,tenant}/providers.tf:5`: `~>5.0`; locks `P:28`, `foundation:28`, `tenant:5`: `5.45.2` | [8.4.0](https://github.com/hashicorp/terraform-provider-google/releases/tag/v8.4.0); legado, não atualizar/aplicar como produção |
| HTTP | locks `P:48`, `foundation:48`: `3.5.0` | [3.6.2](https://registry.terraform.io/providers/hashicorp/http/latest); W12 se ainda usado |
| Null | lock `P:67`: `3.2.4` | [3.3.2](https://github.com/hashicorp/terraform-provider-null/releases/tag/v3.3.2); legado |
| Random | locks `P:86`, `foundation:67`: `3.8.1` | [3.9.1](https://github.com/hashicorp/terraform-provider-random/releases/tag/v3.9.1); W12, preservar segredo do túnel |
| Coolify | `TF/modules/coolify-management/main.tf:5`, `P/tenant/providers.tf:9`: `0.10.2`; locks `P:105`, `tenant:25`: `0.10.2` | [0.10.2](https://registry.terraform.io/providers/sierrajc/coolify/latest), sem upgrade; legado |
| Loki schema | `observability/loki/loki.yaml:44,47,48,49`: TSDB / filesystem / `v13` | Formato, não release; manter histórico e schema v13 |
| Dashboards | `observability/grafana/provisioning/dashboards/{chat-services:116,service-logs-overview:132,traces-overview:95,self-healing-v2:84}.json`: `schemaVersion:39`; versões próprias 1/6/1/9 nas linhas 124/198/150/98 | Formatos de documento; não substituir por versão do Grafana |
| Dify DSL / plugin | `dify-apps/Self-Healing Agent Analysis.yml:13,16`: Azure plugin `0.0.50@61cf7ba70e80065c6828d21d0bb2c0f1a76c99d599c5266fe86f4fe135c27880` (**D**), DSL `0.6.0` | Manter no primeiro upgrade; latest publicado no Marketplace **ASSUMED**, validar import/export |
| Edge | `edge/cloudflare-worker/wrangler.jsonc:5`: `compatibility_date=2026-04-14` | Data de contrato, não release; manter até testes próprios |

Tempo `observability/tempo/tempo.yaml:3` acompanha o pin `3.0.3` após W4b (fixtures 2.6.1 e 2.10.8 preservadas nos testes). Collector, Prometheus e provisioning usam configurações sem pin adicional de software. Azure `gpt-4o`/`gpt-4o-mini` são deployments externos: versão real, API version e disponibilidade **ASSUMED**, não são imagens a atualizar via Compose.

### npm: todos os pins diretos, locks e alvo

Abreviações: **R**=`package.json`, **M**=`middleware/package.json`, **S**=`agents/self-healing/package.json`, **O**=`onboarding/package.json`, **P**=`provisioning/package.json`, **E**=`edge/cloudflare-worker/package.json`. Cada referência inclui a linha. Todos os ranges atuais abaixo são **F** (`^`); `npm ci` usa a versão exata do `package-lock.json`, não o mínimo do range. Edge usa `pnpm-lock.yaml`. Coluna final = latest do registro oficial consultado + alvo, salvo exceção explícita.

| Dependência | Manifesto:linha = range → lock atual | Latest / alvo |
|---|---|---|
| `@fastify/sensible` | M:20 `^6.0.2` → `6.0.4` | [6.0.6](https://www.npmjs.com/package/@fastify/sensible) |
| `@fastify/static` | M:21 `^8.0.3` → `8.3.0` | [10.1.5](https://www.npmjs.com/package/@fastify/static) |
| `@opentelemetry/api` | M:22 `^1.9.1` → `1.9.1`; S:14 `^1.9.1` → `1.9.1` | [1.9.1](https://www.npmjs.com/package/@opentelemetry/api) |
| `@opentelemetry/exporter-trace-otlp-http` | M:23 `^0.219.0` → `0.219.0`; S:15 `^0.219.0` → `0.219.0` | [0.222.0](https://www.npmjs.com/package/@opentelemetry/exporter-trace-otlp-http) |
| `@opentelemetry/instrumentation-fastify` | M:24 `^0.57.0` → `0.57.0` | [0.57.0](https://www.npmjs.com/package/@opentelemetry/instrumentation-fastify) |
| `@opentelemetry/instrumentation-http` | M:25 `^0.219.0` → `0.219.0`; S:16 `^0.219.0` → `0.219.0` | [0.222.0](https://www.npmjs.com/package/@opentelemetry/instrumentation-http) |
| `@opentelemetry/instrumentation-pg` | M:26 `^0.71.0` → `0.71.0`; S:17 `^0.71.0` → `0.71.0` | [0.74.0](https://www.npmjs.com/package/@opentelemetry/instrumentation-pg) |
| `@opentelemetry/instrumentation-pino` | M:27 `^0.65.0` → `0.65.0`; S:18 `^0.65.0` → `0.65.0` | [0.68.0](https://www.npmjs.com/package/@opentelemetry/instrumentation-pino) |
| `@opentelemetry/resources` | M:28 `^2.8.0` → `2.8.0`; S:19 `^2.8.0` → `2.8.0` | [2.11.0](https://www.npmjs.com/package/@opentelemetry/resources) |
| `@opentelemetry/sdk-node` | M:29 `^0.219.0` → `0.219.0`; S:20 `^0.219.0` → `0.219.0` | [0.222.0](https://www.npmjs.com/package/@opentelemetry/sdk-node) |
| `@opentelemetry/sdk-trace-base` | M:30 `^2.8.0` → `2.8.0`; S:21 `^2.8.0` → `2.8.0` | [2.11.0](https://www.npmjs.com/package/@opentelemetry/sdk-trace-base) |
| `@opentelemetry/semantic-conventions` | M:31 `^1.41.1` → `1.41.1`; S:22 `^1.41.1` → `1.41.1` | [1.43.0](https://www.npmjs.com/package/@opentelemetry/semantic-conventions) |
| `@playwright/test` | O:22 `^1.42.1` → `1.59.1` | [1.63.0](https://www.npmjs.com/package/@playwright/test) |
| `@types/node` | R:11 `^22.13.5` → `22.19.19`; M:41 `^22.10.1` → `22.19.17`; S:29 `^20.14.0` → `20.19.39`; P:27 `^22.13.5` → `22.19.18` | [26.6.3; alvo 24.19.0](https://www.npmjs.com/package/@types/node) |
| `@types/pg` | R:12 `^8.20.0` → `8.20.0`; M:42 `^8.20.0` → `8.20.0`; S:30 `^8.11.10` → `8.20.0`; P:28 `^8.11.11` → `8.20.0` | [8.23.1](https://www.npmjs.com/package/@types/pg) |
| `@types/react` | M:43 `^18.3.12` → `18.3.31` | [19.3.0](https://www.npmjs.com/package/@types/react) |
| `@types/react-dom` | M:44 `^18.3.1` → `18.3.7` | [19.3.0](https://www.npmjs.com/package/@types/react-dom) |
| `@vitejs/plugin-react` | M:45 `^4.3.4` → `4.7.0` | [6.1.1](https://www.npmjs.com/package/@vitejs/plugin-react) |
| `axios` | R:13 `^1.7.9` → `1.16.1`; M:32 `^1.7.7` → `1.15.0`; S:23 `^1.7.7` → `1.15.0`; O:23 `^1.7.9` → `1.18.0`; P:20 `^1.7.9` → `1.15.0` | [1.20.0](https://www.npmjs.com/package/axios) |
| `commander` | P:21 `^12.1.0` → `12.1.0` | [15.0.0](https://www.npmjs.com/package/commander) |
| `dotenv` | R:14 `^16.4.7` → `16.6.1`; O:17 `^16.4.5` → `16.6.1`; P:22 `^16.4.7` → `16.6.1` | [18.0.4](https://www.npmjs.com/package/dotenv) |
| `fastify` | M:33 `^5.1.0` → `5.8.4`; O:24 `^5.8.5` → `5.8.5` | [5.12.5](https://www.npmjs.com/package/fastify) |
| `hono` | E:10 `^4.12.12` → `4.12.12` | [4.13.9](https://www.npmjs.com/package/hono) |
| `pg` | R:15 `^8.13.3` → `8.21.0`; M:34 `^8.20.0` → `8.20.0`; S:24 `^8.13.0` → `8.20.0`; P:23 `^8.13.3` → `8.20.0` | [8.23.0](https://www.npmjs.com/package/pg) |
| `pino` | M:35 `^9.5.0` → `9.14.0`; S:25 `^9.4.0` → `9.14.0` | [10.3.1](https://www.npmjs.com/package/pino) |
| `pino-pretty` | M:36 `^13.0.0` → `13.1.3` | [13.1.3](https://www.npmjs.com/package/pino-pretty) |
| `playwright` | O:18 `^1.42.1` → `1.59.1` | [1.63.0](https://www.npmjs.com/package/playwright) |
| `prom-client` | M:37 `^15.1.3` → `15.1.3` | [15.1.3](https://www.npmjs.com/package/prom-client) |
| `react` | M:46 `^18.3.1` → `18.3.1` | [19.3.0](https://www.npmjs.com/package/react) |
| `react-dom` | M:47 `^18.3.1` → `18.3.1` | [19.3.0](https://www.npmjs.com/package/react-dom) |
| `ts-node` | S:31 `^10.9.2` → `10.9.2` | [10.9.2](https://www.npmjs.com/package/ts-node) |
| `tsx` | R:16 `^4.19.3` → `4.22.3`; M:48 `^4.19.2` → `4.21.0`; O:25 `^4.19.3` → `4.21.0` | [4.23.15](https://www.npmjs.com/package/tsx) |
| `typescript` | R:17 `^5.7.3` → `5.9.3`; M:49 `^5.7.2` → `5.9.3`; S:32 `^5.4.5` → `5.9.3`; P:29 `^5.7.3` → `5.9.3` | [7.0.2](https://www.npmjs.com/package/typescript) |
| `vite` | M:50 `^6.0.7` → `6.4.3` | [8.3.1](https://www.npmjs.com/package/vite) |
| `vitest` | M:51 `^4.1.6` → `4.1.6`; S:33 `^2.1.9` → `2.1.9` | [5.0.2](https://www.npmjs.com/package/vitest) |
| `wrangler` | E:13 `^4.4.0` → `4.82.2` | [4.141.0](https://www.npmjs.com/package/wrangler) |
| `yaml` | R:18 `^2.7.0` → `2.9.0`; O:19 `^2.9.0` → `2.9.0` | [2.9.1](https://www.npmjs.com/package/yaml) |
| `zod` | M:38 `^3.23.8` → `3.25.76`; S:26 `^3.23.8` → `3.25.76`; P:24 `^3.24.2` → `3.25.76` | [4.6.5](https://www.npmjs.com/package/zod) |

As versões resolvidas mostram a diferença material: Playwright já é **1.59.1**, não 1.42.1; TS é **5.9.3**, não 5.7; self-healing ainda usa Vitest **2.1.9**. Versões e engines foram consultadas em `registry.npmjs.org/<pacote>/latest`; os links acima identificam os pacotes oficiais. Dependências transitivas não constituem inventário de pins diretos e devem ser reavaliadas pelo lock/audit de cada PR.

## 2. Releases, alvos exatos e risco por componente

Consulta às APIs públicas de releases do GitHub, registry npm, catálogo Docker Hub e documentação oficial; excluídos prereleases. Os links desta seção sustentam versões/notas. Os alvos são propostas, sujeitos aos gates abaixo; tags devem receber digest de manifesto e arquitetura verificados no PR. Não reutilizar um digest de outra arquitetura nem confundir digest de imagem com checksum de binário.

| Componente | Última estável encontrada → alvo | Delta relevante / risco |
|---|---|---|
| Chatwoot rails/sidekiq/init | [4.18.0](https://github.com/chatwoot/chatwoot/releases/tag/v4.18.0) → `chatwoot/chatwoot:v4.18.0-ce` | **Alto**: schema Rails, sessões, uploads e webhooks; preservar CE em todos os três serviços |
| Dify api/web/worker | [1.17.1](https://github.com/langgenius/dify/releases/tag/1.17.1) → `langgenius/dify-{api,web}:1.17.1` | **Alto**: Alembic + migração de dados/provider; worker usa imagem api; não habilitar Agent Beta automaticamente |
| Dify sandbox | [0.2.15](https://github.com/langgenius/dify-sandbox/releases/tag/0.2.15) → `langgenius/dify-sandbox:0.2.15` | **Médio**: execução via fd3, seccomp, ordem de redução de privilégios e UIDs por execução |
| Dify plugin-daemon | [0.6.10](https://github.com/langgenius/dify-plugin-daemon/releases/tag/0.6.10) → `langgenius/dify-plugin-daemon:0.6.10-local` | **Alto**: storage, DB/plugin API; tipo `date-picker` renomeado `date-range`; manter variante `-local` |
| Dify ssrf-proxy | [Squid 7.7](https://www.squid-cache.org/Versions/) | **Resolvido na W7a**: nenhuma imagem `ubuntu/squid` traz 7.x, então a imagem é construída no repo a partir do tarball oficial verificado |
| Dify init / helper backup | [Alpine 3.24.2](https://alpinelinux.org/releases/) → `alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6` | **Baixo**: tar/chown, UID 1001 e permissões; imagens auxiliares também precisam digest |
| Evolution API | [2.3.7](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.7) → `evoapicloud/evolution-api:v2.3.7` | **Alto**, embora ordenado antes de Dify: Prisma, Baileys, LID/JID, sessões e integração Chatwoot |
| PostgreSQL + pgvector | [PG 18.6; PG16 16.15](https://www.postgresql.org/support/versioning/) + [vector 0.8.6](https://github.com/pgvector/pgvector/blob/master/CHANGELOG.md) | **Crítico**: primeiro fixar PG16 + vector 0.8.6; major 18.6 apenas W14 opcional, dump/restore |
| Redis | [8.10.2](https://github.com/redis/redis/releases/tag/8.10.2) → inicialmente `redis:7.2.16-alpine`; depois `redis:8.10.2-alpine` | Patch [7.2.16](https://github.com/redis/redis/releases/tag/7.2.16) reduz salto inicial; major exige prova Sidekiq/Celery e backup RDB/AOF |
| Traefik | [3.7.13](https://github.com/traefik/traefik/releases/tag/v3.7.13) → `traefik:v3.7.13` | **Médio**: único ingresso, regras/headers mais estritos; validar Docker provider independentemente do fallback |
| cloudflared | [2026.9.3](https://github.com/cloudflare/cloudflared/releases/tag/2026.9.3) → `cloudflare/cloudflared:2026.9.3` | **Médio**: túnel único; baseline `latest` desconhecida, intervalo de upgrade **ASSUMED** |
| Loki | [3.7.8](https://github.com/grafana/loki/releases/tag/v3.7.8) → `grafana/loki:3.7.8` | **Médio/alto**: validação YAML, índices, retenção e sondas sem shell |
| Promtail → Alloy | Tag Promtail [3.6.11](https://hub.docker.com/r/grafana/promtail/tags) encontrada; alvo [Alloy 1.20.0](https://github.com/grafana/alloy/releases/tag/v1.20.0) → `grafana/alloy:v1.20.0` | Promtail [EOL em 02/03/2026](https://grafana.com/docs/loki/latest/send-data/promtail/); tag disponível não significa suporte; migrar labels/positions/PII |
| Prometheus | [3.15.0](https://github.com/prometheus/prometheus/releases/tag/v3.15.0) → `prom/prometheus:v3.15.0` | **Alto**: major 2→3, PromQL/protocolos de scrape/TSDB |
| Grafana | [13.2.2](https://github.com/grafana/grafana/releases/tag/v13.2.2) → `grafana/grafana:13.2.2` | **Alto**: migrações do DB `grafana`, dashboards, plugins e alerting; ponte 12.4.11 em PR próprio |
| Tempo | [3.0.3](https://github.com/grafana/tempo/releases/tag/v3.0.3) → primeiro `grafana/tempo:2.10.8`, depois `3.0.3` | **Alto**: 3.x remove ingester/compactor; sem downgrade suportado; não exige Kafka no modo monolítico |
| OTel Collector | [0.161.0](https://github.com/open-telemetry/opentelemetry-collector-releases/releases/tag/v0.161.0) → `otel/opentelemetry-collector-contrib:0.161.0` | **Médio**: 0.x tem mudanças incompatíveis; exporter Prometheus e métricas devem ser comparados |
| autoheal | [1.2.0](https://hub.docker.com/r/willfarrell/autoheal/tags) é último tag semver encontrado; manter | Sem GitHub releases; `latest` possui alterações sem release estável identificada. Compatibilidade com Engine atual **ASSUMED**, não trocar cegamente |
| Node middleware/self-healing | [Current 26.10.0; LTS 24.21.0](https://github.com/nodejs/node/releases) → `node:24.21.0-alpine3.24` nos seis FROM | **Médio**: Node20 EOL; uniformizar Node de CI/engines/types, testar ESM `--import` e CJS `--require` |

O conjunto Dify proposto está confirmado no [Compose oficial 1.17.1](https://github.com/langgenius/dify/blob/1.17.1/docker/docker-compose.yaml). `0.5.3-local` é variante publicada do plugin-daemon, não evidência de fork local. Para PostgreSQL, `pgvector/pgvector:0.8.6-pg16-bookworm` e `0.8.6-pg18-bookworm` existem; essas tags **não fixam o patch PG**. Alvo lógico W13 = PG16.15/vector0.8.6, W14 = PG18.6/vector0.8.6. Confirmar a versão embarcada no digest; se não atender, construir imagem versionada sobre `postgres:16.15-bookworm`/`18.6-bookworm` + fonte vector0.8.6, com receita e checksums em código. Não afirmar que o tag pg18 já contém 18.6.

### Leituras intermediárias e contratos realmente usados

- **Chatwoot 4.13→4.18:** notas 4.14.x endurecem SSRF/webhooks; 4.15.x alteram sessões/contadores; 4.16.1 corrige bloqueios de Public API/webhooks; 4.17.1 corrige login Instagram; 4.18 reforça autenticação/mídia. Fontes: [histórico](https://github.com/chatwoot/chatwoot/releases), [4.14.1](https://github.com/chatwoot/chatwoot/releases/tag/v4.14.1), [4.16.1](https://github.com/chatwoot/chatwoot/releases/tag/v4.16.1), [4.17.1](https://github.com/chatwoot/chatwoot/releases/tag/v4.17.1). Não foi encontrada remoção declarada das rotas usadas, mas compatibilidade de payload é **ASSUMED** até fixtures **sintéticas** (repo público: nunca derivar de payloads reais com telefone, nome, e-mail ou conteúdo de mensagem).
- `middleware/src/chatwoot.ts:44,66,78,90` usa mensagens, atributos, toggle_status e labels via `/api/v1/accounts/...`, header `api_access_token` (com underscores: testar passagem pelo Traefik novo); `handlers/admin.ts:405,416,424,490` usa Platform API. O webhook (`handlers/chatwoot-webhook.ts:744,775`) exige `message_created`, inbound/não privado, IDs/contato/account e atributos; manter token de query redigido, debounce, watermark e isolamento entre tenants/contatos. Endurecimento de SSRF pode bloquear o callback para `middleware:4000`: testar política e exceção restrita, nunca desativar globalmente.
- `deploy/ai_agents.rb:3` faz `require 'agents'` e usa `LlmConstants`: [Gemfile 4.18](https://github.com/chatwoot/chatwoot/blob/v4.18.0/Gemfile) ainda contém `ai-agents`; [constantes](https://github.com/chatwoot/chatwoot/blob/v4.18.0/lib/llm_constants.rb) existem. Isso elimina a hipótese de remoção direta, mas não prova funcionamento do initializer CE; boot de init/rails/sidekiq é gate.
- **Dify 1.14→1.17.1:** [1.14.1](https://github.com/langgenius/dify/releases/tag/1.14.1) altera tratamento de SECRET_KEY; preservar chave explícita/RSA. [1.14.2](https://github.com/langgenius/dify/releases/tag/1.14.2) reorganiza envs; [1.15](https://github.com/langgenius/dify/releases/tag/1.15.0) corrige forwarding do plugin/SSRF; [1.16](https://github.com/langgenius/dify/releases/tag/1.16.0) introduz Agent Beta e schema; [1.17](https://github.com/langgenius/dify/releases/tag/1.17.0) renomeia `EDITION`→`DEPLOYMENT_EDITION`, remove `ENTERPRISE_ENABLED`, muda timeouts e runtime Agent. Esses campos não estão no Compose local; defaults novos ainda precisam diff explícito. Não copiar o Compose upstream inteiro nem seus comandos de `down`.
- Em **1.17.1**, a conversão dos tipos legados `text-generation/embeddings/reranking` passa a integrar `flask db upgrade`; 1.16/1.17.0 exigiam comando separado. Preferir destino direto 1.17.1 ensaiado em CI com fixture antiga. Há migrações destrutivas de runtime Agent e índice de conversas potencialmente demorado. O alerta Weaviate não se aplica ao código local, que usa pgvector; não instalar Weaviate.
- `middleware/src/dify.ts:51,61,82,117` usa `/chat-messages` blocking/SSE, `conversation_id`, `message/agent_message/message_end/error` e `metadata.usage`; `handlers/admin.ts:615,624,645` consulta diretamente `apps/api_tokens` (fallback `app`). [Modelo upstream](https://github.com/langgenius/dify/blob/1.17.1/api/models/model.py) preserva `apps`; semântica de tokens/modes/Agent novo **ASSUMED**. Exercitar descoberta/admin, além da API pública. Self-healing também precisa concluir análise com chave obtida em `/config`.
- **Handoff não é HITL nativo Dify:** `middleware/src/handlers/handoff.ts:29,49,54,59` recebe `/tools/handoff` com `x-handoff-secret`, reabre conversa, aplica `atendimento-humano` e nota privada. O Compose atual do Squid não monta ACL/config nem explicita HTTP_PROXY/HTTPS_PROXY no sandbox; presença do container não prova proteção. Transportar envs de proxy e ACL restrita para esse endpoint interno e comprovar bloqueio de outros IPs privados/metadata.
- **Evolution 2.1.1→2.3.7:** [histórico 2.2/2.3](https://github.com/evolution-foundation/evolution-api/releases) contém migrações Prisma, mudanças LID/JID, deduplicação de contatos, reconexão e mídia; 2.3.7 adiciona `isLatest/progress` a `messages.set`, índice único `(instanceId,remoteJid)` e corrige chaves Redis. Comparar [env de destino](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/.env.example), em especial `CHATWOOT_ENABLED` cujo default é false. Middleware recebe webhook do Chatwoot, não o payload bruto Evolution: testar ambos os saltos; Instagram continua nativo Chatwoot.
- **Loki:** [guia de upgrade](https://grafana.com/docs/loki/latest/setup/upgrade/) registra remoção de BusyBox desde 3.5.8; `deploy/docker-compose.nexaduo.yml:113` e `scripts/health-check-all.sh:226,231` dependem de wget interno e quebrariam. Trocar por sonda HTTP externa verificável e ajustar a regra de cobertura, sem declarar saudável só pelo processo. Já existe TSDB/v13; manter períodos históricos. `table_manager` não comprova retenção TSDB: validar/configurar compactor antes de deletar dados. Bloom experimental não está habilitado.
- **Prometheus:** [migração 3.0](https://prometheus.io/docs/prometheus/latest/migration/) muda regex/range semantics e exige Content-Type de scrape válido. Comparar séries e alertas antes/depois, inclusive token usage por account_id; não mascarar endpoint errado com fallback indiscriminado. Preservar snapshot TSDB porque voltar a v2 não significa que WAL novo seja legível.
- **Grafana:** [v12](https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v12.0/) migra annotations e exige UIDs válidos; UIDs locais `loki`, `tempo`, `prometheus`, `postgres-self-healing-v2` são compatíveis em formato. [v13](https://grafana.com/docs/grafana/latest/upgrade-guide/upgrade-v13.0/) muda armazenamento de dashboards/folders, remove comandos `grafana-cli/server` e renderer plugin, desabilita datasource API por ID numérico. Usar 13.2.2, não 13.0.0 retirado. Banco real aqui é PostgreSQL, não apenas `grafana-data`.
- **Tempo:** [migração v3.0.3](https://github.com/grafana/tempo/blob/v3.0.3/docs/sources/tempo/set-up-for-tracing/setup-tempo/migrate-to-3.md) exige vParquet4+, remove blocos `ingester`/`compactor` (migrados em W4b) e não oferece downgrade 3→2. Fazer ponte 2.10.8, verificar blocos em disco e migrar config monolítica. [Collector changelog](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.161.0/CHANGELOG.md): normalização de nomes/sufixos Prometheus e mudanças health_check requerem comparação; não usamos os exporters removidos Loki/Jaeger.
- **Proxy:** [Traefik 3.7](https://doc.traefik.io/traefik/v3.7/migrate/v3/) altera normalização/headers, incluindo h2c; verificar SSE, WebSocket, downloads e headers de autenticação. Cloudflared publica principalmente checksums, sem narrativa completa de migração: diff desde o digest realmente instalado permanece **ASSUMED**.
- **Redis/PG:** Redis mantém fila durável, `noeviction`, 150 MB/256 MB; testar AOF/RDB e reconexões. Revisar [notas 7.2](https://github.com/redis/redis/releases/tag/7.2.16), [8.10](https://github.com/redis/redis/blob/8.10.2/00-RELEASENOTES) e licenças antes da major. [PG17](https://www.postgresql.org/docs/release/17.0/)/[PG18](https://www.postgresql.org/docs/release/18.0/) mudam manutenção/search_path e checksums/auth MD5; major exige migração, e neste plano exclusivamente dump/restore em volume novo. pgvector 0.8.2–0.8.6 corrige HNSW/IVFFlat; versão instalada da extensão é **ASSUMED** até `pg_extension`, distinta da biblioteca presente na imagem.

### Risco npm/CI e itens que não são upgrades automáticos

[Vitest 5](https://vitest.dev/guide/migration/) requer Node ≥22.12 e Vite ≥6.4, muda pools/mocks (`clearMocks` default true); atravessar guias 3/4/5 para self-healing. [Playwright](https://playwright.dev/docs/release-notes) deve atualizar `playwright` e `@playwright/test` juntos e reinstalar browsers; não presumir que cache antigo serve. [Vite 8](https://vite.dev/guide/migration) troca bundler por Rolldown: validar build e assets da UI.

[React 19](https://react.dev/blog/2024/04/25/react-19-upgrade-guide) remove APIs antigas; atualizar react-dom/types juntos. [TS7](https://devblogs.microsoft.com/typescript/announcing-typescript-7-0/) é port nativo: migração separada e avaliar `ts-node` 10.9.2 antes de trocar compilador. [Zod4](https://zod.dev/v4/changelog) altera schemas/erros; [Commander15](https://github.com/tj/commander.js/releases/tag/v15.0.0) é ESM-only e muda defaults de flags; provisioning é ESM, mas precisa smoke de CLI. [Pino10](https://github.com/pinojs/pino/releases) exige validar transports/serializers e redaction. [dotenv18](https://github.com/motdotla/dotenv/blob/master/CHANGELOG.md) altera parser/logging: verificar sem expor valores.

Atualizar [Axios](https://github.com/axios/axios/releases/tag/v1.20.0), [Fastify](https://github.com/fastify/fastify/releases/tag/v5.12.5), pg e OTel com locks juntos; plugins Fastify precisam matriz compatível; [static10.1.5 documenta Fastify5](https://github.com/fastify/fastify-static/blob/v10.1.5/README.md), mas seu salto major fica em W10b com testes de assets. OTel stable 2.11.0 e experimental 0.222.0 formam conjunto; não alinhar todos artificialmente ao mesmo número. Revisão de **todos** os patches intermediários de npm/actions/Collector/Grafana não foi exaustiva: efeitos adicionais são **ASSUMED**, gate de changelog/diff por PR, nunca declaração “sem breaking changes”.

## 3. Procedimento comum de cada onda com alteração em produção

1. Uma onda = **um PR**, inclusive sufixos `a/b`. Sem PR agregado. Atualizar código, locks, exemplos sem secrets, scripts e documentação juntos. Rodar os quatro checks requeridos (`validate-stack`, `secret-scan`, `middleware`, `self-healing`), acompanhar com `gh run watch`, revisar @sec/@rev conforme convenção e só então merge. Não contornar proteção nem reativar workflows GCP. Regressões web em `onboarding/tests/`; explicar N/A para lógica exclusivamente interna.
2. Antes do apply, coordenar janela e guardar pins/digests/config anteriores, versões reais, contagens de dados, filas, espaço livre e memória. CI testa também upgrade de **fixture sintética na versão antiga**, não só banco vazio; usar job efêmero, sem criar staging e sem copiar segredos/dados pessoais de produção.
3. Rodar **`scripts/backup-host.sh` imediatamente antes de cada onda**; verificar exit 0, `.last-success`, `gzip -t`, conteúdo/contagens, tar íntegro e cópia off-host. O código atual cobre todos os DBs + chatwoot-storage/dify-api-storage/evolution-instances/grafana-data + `.env`; difere do resumo histórico do AGENTS.md. Acrescentar em código backup de `dify-plugin-storage`, `redis-data`, Loki/Tempo/Prometheus/positions conforme onda. DB+filesystem devem representar ponto consistente: pausar escritores da onda antes do backup final, drenar jobs; dump de vários DBs não é snapshot global.
4. Preservar `chat-services_postgres-data`, rede `nexaduo-network`, logs limitados, isolamento de portas e chaves. Preparar imagens antes da interrupção. **Nunca `down -v`, prune, bootstrap/restore global ou up sem lista no host.** Não executar restore de junho como rollback de upgrade recente; usar backup fresco validado da onda.
5. Aplicar somente serviços afetados pela função abaixo; `--no-deps` é obrigatório. Após migrar/configurar, `scripts/run-stack.sh validate`, `scripts/health-check-all.sh`, `npm run test:all` em onboarding com URLs reais, mais critérios da onda. Registrar limitações reais; checks de CI não cobrem Meta nem túnel. Não concluir no HTTP 200 de enqueue.
6. Observar por pelo menos um ciclo de carga e backup (proposta 24 h entre ondas), acompanhando OOM/restarts, filas, latência, erros e terminal state. Critério de abortar: migração falha, perda/duplicação, vazamento entre tenants, erro novo de auth, webhook/handoff/RAG falhando, fila crescendo sem drenar ou ausência de logs/métricas. Registrar incidentes conhecidos sem transformá-los em falso verde.

Comandos **para execução futura**, na raiz do repo, usando `.env` de produção e a mesma ordem de `scripts/run-stack.sh:68`:

```bash
dc() {
  docker compose --project-name chat-services --env-file .env \
    -f deploy/docker-compose.shared.yml \
    -f deploy/docker-compose.chatwoot.yml \
    -f deploy/docker-compose.dify.yml \
    -f deploy/docker-compose.nexaduo.yml \
    -f docker-compose.yml \
    -f deploy/docker-compose.localproxy.yml \
    -f deploy/docker-compose.isolated.yml "$@"
}
# Cada PR fornece a lista literal de serviços; não usar lista vazia.
# dc pull <serviços>; dc up -d --no-deps <serviços>
scripts/run-stack.sh validate
scripts/health-check-all.sh
```

**Rollback R0 (sem alteração persistente):** reverter PR/pin/config ao artefato anterior imutável e `dc up -d --no-deps` apenas nos serviços da onda. **R1 (schema/storage):** bloquear entradas/escritores afetados, arquivar estado pós-falha para reconciliação, restaurar somente DBs/volumes indicados a partir do backup da onda, então subir pins antigos. Para um DB no PG atual: parar consumidores, terminar conexões, recriar **o DB**, importar o dump (`zcat <dump-validado> | docker exec -i chat-services-postgres-1 psql -v ON_ERROR_STOP=1 -U postgres -d <db>`), restaurar tar correspondente com consumidores parados e validar contagens/anexos. Não recriar container PG para isso. Não fazer `rails db:rollback`/`flask db downgrade` como garantia genérica. Escritas posteriores ao backup exigem reconciliação explícita; não prometer rollback sem perda após reabrir tráfego.

## 4. Ondas ordenadas — cada linha é um PR

Todos os pré-passos, gates, validações e rollback comuns acima são parte de cada linha. `N` abaixo significa `deploy/docker-compose.nexaduo.yml`; `S` = shared; `D` = dify; `C` = chatwoot; `CI` = `.github/workflows/stack-compose-playwright.yml`. S/C/D também são `deploy/docker-compose.<nome>.yml`.

| Onda / alvo | Arquivos a alterar | Aplicação restrita e checks específicos | Rollback / CI |
|---|---|---|---|
| **W0a — gates/pins de tooling**: checkout7.0.1, setup-node7.0.0, Gitleaks8.30.1; Node CI24.21.0, runner ubuntu-24.04 | CI, unit-tests.yml, validate-tenants.yml; checksums/SHAs, fixtures de upgrade | Nenhum serviço live a recriar. Provar quatro checks, permissões/cache/credenciais checkout; não acionar publish/deploy/power GCP | Reverter workflow; **CI muda**. Backup/apply/validate live N/A, declarar no PR |
| **W0b — runner 26.04** | Mesmos workflows ativos | Testar browsers, Compose `!reset`, Docker provider em CI; fixar ubuntu-26.04 após verde | Reverter ubuntu-24.04; **CI muda**; produção N/A |
| **W1a — cloudflared2026.9.3, autoheal mantido1.2.0 fixado por digest** | S; `.env.production.example` se necessário | `dc up -d --no-deps cloudflared autoheal`; `tunnel ready`, todos os domínios, política de labels autoheal; simular unhealthy só no runner | R0; CI deve testar watcher sintético, pois hoje ambos são escalados a zero |
| **W1b — Traefik3.7.13** | localproxy, `deploy/traefik/dynamic.yml` se necessário | `dc up -d --no-deps coolify-proxy`; API interna lista routers `@docker` enabled, negar API a container vizinho, SSE/WebSocket/redirect/cookie | R0; adicionar proxy efêmero e probes ao CI sem token de túnel |
| **W2a — Loki3.7.8** | N, `observability/loki/loki.yaml`, health-check-all.sh, testes de sondas | Backup `loki-data`; corrigir wget antes. `dc up -d --no-deps loki`; `/ready` externo, query_range histórico/novo, ingest/metadata e limites | R1 volume Loki se formato incompatível; **CI muda** sondas/config validation |
| **W2b — Alloy1.20.0 substitui Promtail** | N, root, isolated, nova `observability/alloy/`, scripts de bootstrap/health, dashboards/self-healing se labels mudarem | Guardar positions. `dc stop promtail`; `dc up -d --no-deps alloy`; remover container legado só depois da validação, preservar volume. Conferir labels, PII mascarada, trace/account IDs metadata, continuidade sem reingestão maciça | Parar Alloy, R0 Promtail3.1.0 + positions preservadas; **CI muda**, cobertura de serviço/limites/checksum |
| **W2c — Collector0.161.0** | N, `observability/otel-collector/config.yaml`, health-check-all.sh | `dc up -d --no-deps otel-collector`; `/health`, scrape8889, trace sintético em Tempo, comparar nomes/tipos/sufixos | R0; **CI muda**, teste OTLP→Prometheus/Tempo |
| **W3a — Prometheus3.15.0** | N, `observability/prometheus/`, regras/Grafana quando necessário | Snapshot/backup `prometheus-data`; `dc up -d --no-deps prometheus`; promtool, targets up, consultas token/account equivalentes e alertas avaliando | R1 TSDB +2.55.0; **CI muda** promtool/scrapes |
| **W3b — Grafana12.4.11** | N, provisioning, testes onboarding | Backup DB `grafana` + volume; `dc up -d --no-deps grafana`; esperar migrations, login, quatro dashboards, datasources e token alerts | R1 DB/volume +11.6.16; **CI muda** fixture11→12 |
| **W3c — Grafana13.2.2** | Mesmos arquivos, scripts antigos CLI/APIs se encontrados | Novo backup após W3b; `dc up -d --no-deps grafana`; verificar unified storage, UIDs, annotations, alert rules/provisioning e links logs→traces | R1 DB/volume +12.4.11; **CI muda** fixture12→13 |
| **W4a — Tempo2.10.8** | N, `observability/tempo/tempo.yaml` | Backup `tempo-data`; `dc up -d --no-deps tempo`; traces novos e históricos, preparar blocos vParquet4+ sem perder retenção120h | R1 volume +2.6.1; **CI muda** teste TraceQL/OTLP |
| **W4b — Tempo3.0.3** | N, YAML Tempo, dashboards/health se necessário | Novo backup; migrar config monolítica, remover ingester/compactor; `dc up -d --no-deps tempo`; testar ingestão e busca de traces antigos/novos | **R1 obrigatório**, restaurar backup2.10.8; **CI muda** fixture de blocos e config |
| **W5a — Redis7.2.16-alpine** | S | Drenar filas/parar produtores e consumidores, backup frio redis-data; `dc up -d --no-deps redis`; PING auth, AOF OK, noeviction, tarefas Sidekiq/Celery concluídas após restart | R1 Redis7.2.4+AOF/RDB; CI: simular persistência/reconexão |
| **W5b — Redis8.10.2-alpine** (evidência no contrato abaixo) | S, documentação de clientes/licença | Só após provar compatibilidade dos clientes atuais; novo backup frio; `dc up -d --no-deps redis`; mesmas verificações, sem aumentar memória implicitamente | R1 dados7.2.16+pin, nunca abrir AOF8 com7; **CI muda**, se falhar adiar até após Chatwoot |
| **W6 — Evolution2.3.7** | N, fixture Prisma/API, CI; contrato abaixo (sem nova chave de operador) | Backup DB evolution + volume/sessões Redis; suspender autoheal durante migrations; `dc up -d --no-deps evolution-api`; esperar Prisma e reconectar instância; texto/áudio/documento inbound/outbound pelo Chatwoot, sem contatos duplicados | R1 evolution/instances/chaves Redis da instância +2.1.1; **CI muda**, migrations/fixtures, Meta validado live |
| **W6b — Alpine3.24.2** | D, backup-host.sh, sondas Tempo/Collector | Init em fixture, round-trip de arquivo; nada recriado live; próximo backup usa o helper novo | R0 referências anteriores; CI: `test-alpine-helpers.sh` + guard de backup |
| **W7a — Squid7.7** | D, `deploy/squid/Dockerfile` + `squid.conf`, CI; contrato abaixo | Build Squid7.7 com checksum e assinatura, ACL e proxy envs; `dc build dify-ssrf-proxy` e `dc up -d --no-deps dify-ssrf-proxy`; Alpine separado em W6b | R0 imagem/config anterior capturada; **CI muda** ACL, HTTP tool e sandbox |
| **W7b — Dify1.17.1 + sandbox0.2.15 + plugin0.6.10-local** | D, root/isolated/CI override se serviços mudarem, `.env.production.example`, dify-apps, clients/testes middleware/admin | Backup `dify`, `dify_plugin`, api-storage+plugin-storage; sequência detalhada abaixo; checks RAG/Azure/SSE/handoff/config; init Alpine já fixado em W6b | R1 dois DBs+volumes+pins1.13.3/0.2.14/0.5.3-local; **CI muda**, upgrade fixture e readiness |
| **W8 — Chatwoot4.18.0-ce (3 pins)** | C, ai_agents.rb se necessário, onboarding/fixtures webhook | Backup chatwoot+storage; migrar antes de rails/sidekiq, sequência abaixo; login/admin/Platform API/attachments/WhatsApp/Instagram/handoff | R1 DB+storage+4.13.0-ce; **CI muda**, fixture Rails/CE e onboarding |
| **W9 — Node24.21.0-alpine3.24; npm compatíveis** | Dois Dockerfiles, M/S/R/O/P manifests+locks, engines/types24.19.0, workflows ativos, exemplos de imagem | Axios1.20.0, Fastify5.12.5, pg8.23.0, OTel conjunto da tabela; demais updates dentro da mesma major da tabela (sensible6.0.6, types/pg8.23.1, tsx4.23.15, yaml2.9.1); manter por ora os majors separados em W10. Builds por commit+digest; `dc up -d --no-deps middleware self-healing-agent`; testar ESM/CJS, Config API fail-loud, auth/redaction/debounce | R0 imagens anteriores; **CI muda**, npm ci/build/typecheck/unit nos dois pacotes |
| **W10a — Vitest5.0.2 / Playwright1.63.0** | M/S/O manifests+locks, configs Vitest/Playwright e fixtures | Node W9 pré-requisito. npm test em M/S; onboarding test:all e browsers novos; corrigir mocks/pools sem enfraquecer assertions; subir M/S apenas se artefato prod mudar | R0 locks/imagens; **CI muda** cache/browsers e suites |
| **W10b — React19.3.0 / Vite8.3.1 / plugin-react6.1.1 / fastify-static10.1.5** | M manifests+lock, UI/configs e tipos React19.3.0 | Build UI, assets/cache/paths do static, autenticação/admin/tenant/import/discovery e rotas; `dc up -d --no-deps middleware` | R0 middleware anterior; **CI muda** build/UI tests |
| **W10c — Zod4.6.5 / Pino10.3.1 / dotenv18.0.4 / Commander15.0.0** | M/S/R/O/P conforme tabela, schemas/loggers/CLI+locks | Refatorar schemas/erros/redaction em código; CLI dry-run sem criação real; `dc up -d --no-deps middleware self-healing-agent`; validar tenants/config e dados inválidos | R0; **CI muda** contratos unitários e CLI |
| **W10d — TypeScript7.0.2** | R/M/S/P manifests+locks, tsconfigs, scripts ts-node se necessário | Validar port nativo, build e typecheck todos; substituir ts-node somente com versão/alternativa demonstrada; `dc up -d --no-deps middleware self-healing-agent` se rebuild | R0 TS5.9.3/imagens; **CI muda**; bloquear se toolchain não compatível |
| **W11 — Edge Hono4.13.9 / Wrangler4.141.0** | E manifest+pnpm lock; manter compatibility_date | Build/dry-run e contrato `/resolve-tenant`, cookies/headers/tenant no worker; sem Compose apply. Deploy externo depende de identificar rota ativa, hoje **ASSUMED** | Versão anterior do worker + lock; **CI muda** para teste edge; live fase documentada como bloqueada enquanto rota desconhecida |
| **W12 — Terraform Cloudflare5.26.0 + HTTP3.6.2/Random3.9.1; CLI1.16.4** | Somente módulo/raiz Cloudflare ativa isolada do legado, locks e testes | Exportar state protegido (contém o segredo do túnel: nunca commitar nem subir como artefato de CI; apagar ao final), migrar HCL/state seguindo guia; exigir plan sem destruir/recriar túnel/DNS/secret. `terraform apply` só do plan revisado; nenhum dc up; validar rotas/túnel | Reverter HCL/provider+state com cuidado, reconciliar recursos; **CI muda**, validate/test/plan; não aplicar foundation GCP inteira |
| **W13 — PG16.15 + vector0.8.6 fixados** | S, receita de imagem se necessária, init idempotente, backup/restore/tests | Janela própria com todos os consumidores parados; preservar volume; `dc up -d --no-deps postgres` **somente nesta janela planejada**; atualizar extensão por DB, contagens/vetores/RAG | R1 para alteração extensão; imagem anterior só se compatível; **CI muda**, restore PG16 e índices |
| **W14 — PG18.6 + vector0.8.6, opcional/última** | S/root, novo volume/config PGDATA, scripts backup/restore, CI/init | Dump/restore em **volume novo**; trocar serviço postgres só após ensaio/verificação; detalhes abaixo | Retornar a PG16 no volume preservado, reconciliar escritas; **CI muda** fixture major16→18 |

Actions upload-artifact7.0.1, setup-buildx4.4.1, metadata6.2.0, build-push7.4.0, auth3 e setup-gcloud3.0.1 estão no inventário, mas só aparecem em fluxos legados/reutilizados GCP neste repo. Decisão: manter desligados; se criar publicação GHCR host-local em W9, usar targets novos fixados por commit e permissões mínimas. Não “atualizar” o legado executando-o. Terraform Google/Null/Coolify seguem a mesma decisão de retenção histórica, com latest documentado.

### Sequências críticas que a tabela não substitui

**W7b — Dify:** ativar kill switch pela Config API conforme `docs/dify-kill-switch.md`, confirmar que flush não chama Dify e manter mensagens no Chatwoot; drenar workflows/ingestão e parar web/api/worker/plugin. Pausar autoheal durante a janela. Backup final consistente. Migrar uma única vez com imagem destino, por exemplo `dc run --rm --no-deps -e MIGRATION_ENABLED=false --entrypoint flask dify-api db upgrade` (entrypoint/working-dir ensaiados em CI). Confirmar revision/head e conversão dos tipos/modelos; não repetir o comando legado `data-migrate` de 1.17.0 desnecessariamente. Subir `dc up -d --no-deps dify-sandbox dify-ssrf-proxy dify-plugin-daemon`, esperar DB/plugin ready; depois `dc up -d --no-deps dify-api dify-worker dify-web`, verificar saúde e reativar autoheal. Garantir que worker não disputa migration e compartilha envs necessários com api. O upstream usa também beat e novos serviços Agent: determinar necessidade para workflows já usados, versionar `dify-worker-beat` com `dify-api:1.17.1` se necessário; manter Agent Beta desabilitado, sem importar sandbox/agent-backend adicionais por acidente. Necessidade exata de beat **ASSUMED** e bloqueante até ensaio.

Verificações Dify: login/refresh sem401/500; importar/exportar DSL; invocar Azure com credencial existente (sem reset de RSA); ingerir documento sintético e recuperar trecho esperado via pgvector; código Python/JS; SSE completo com IDs/usage; duas conversas Chatwoot do mesmo contato preservam memória, contatos distintos não compartilham; ferramenta handoff abre/rotula/anota; admin lista apps/chaves sem expô-las; self-healing conclui análise sintética. Reabrir tráfego e desligar kill switch só após comprovar terminal state. Backup plugin-storage é gate, pois script atual não o inclui por default.

**W8 — Chatwoot:** suspender automação Dify, bloquear ingresso de escrita na janela e drenar Sidekiq; parar rails/sidekiq, backup final. Executar `dc run --rm --no-deps chatwoot-init` com pin CE novo: o comando versionado faz `rails db:prepare` (aplica migrations pendentes), seguido de limpeza condicional de onboarding. Verificar `rails db:migrate:status`; se o PR escolher `bundle exec rails db:migrate` explícito, não executar os dois fluxos concorrentes. Só então `dc up -d --no-deps chatwoot-rails chatwoot-sidekiq`. Validar `deploy/ai_agents.rb`, anexos antigos/novos, admin multitenant, cookies/TLS, inbound e reply. Instagram: janela24h válida, saída `sent` **com source_id** e log Sidekiq, evitando confundir eco nativo com envio API. Erro2534037 continua questão de Conversation Routing, não corrigir via upgrade/middleware por suposição.

**W5 — Redis:** pausar todos os produtores/consumidores que usam o Redis compartilhado, inclusive apps não recriados; não descartar filas para facilitar migração. Backup AOF/RDB com Redis parado após shutdown limpo; retomada na mesma ordem, observar processamento terminal. W5b exige matriz efetiva das versões de gems/redis-py/Baileys, hoje **ASSUMED**; sem evidência, manter7.2.16 e reprogramar o PR após W8.

**W13/W14 — PostgreSQL:** consultar antes versão do server, `pg_extension`, espaço para duas cópias, permissões/roles, collation e PGDATA. Backup fresco de todos DBs + roles/globals + volumes/.env; testar restauração completa e pgvector em CI efêmera. Em W13, atualizar biblioteca e `ALTER EXTENSION vector UPDATE` nos DBs que a usam; alterações do schema middleware/self_healing somente em `01-init.sql` idempotente. Reindex quando exigido pelas notas/checagem de índices, não presumir que bump de container atualizou extensões.

Em W14, parar **todos** os consumidores para snapshot final consistente; criar volume `chat-services_postgres18-data`, nunca montar `chat-services_postgres-data` em PG18. Versionar override de volume e PGDATA: imagens PG18 podem mudar layout de dados, conferir contrato da imagem escolhida. Inicializar PG18, restaurar roles e cada dump com erro fatal, conferir contagens/checksums lógicos, sequences, constraints, índices vetoriais, queries e RAG. Só depois ligar consumidores usando o serviço `postgres`. Comandos futuros incluem `dc up -d --no-deps postgres` exclusivamente após o override novo e janela de cutover. Guardar PG16/volume antigo intactos até expirar retenção de rollback. Falha antes de abrir escrita: voltar override/pin e iniciar PG16 antigo. Falha depois: parar escritores, preservar novo estado e decidir reconciliação; dump PG18 não é garantia de restore reverso em16. Nunca `pg_upgrade` in-place nem exclusão do volume sagrado neste plano.

## 5. Evidência, lacunas e critério de liberação

- **Verificado:** pins/linhas dos arquivos, ranges e locks diretos, contratos citados, releases e conjunto Dify upstream. Exemplos de digests confirmados pelo catálogo: Node24.21.0-alpine3.24 `sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1`; Chatwoot4.18.0-ce `sha256:faaa58a911cda8f2ab9d717ddf8ca4332163b07da4c5da10711d896e5d667442`; Evolution2.3.7 `sha256:1bd8afc4a6cf48822e6cf02469aeae7bd35a12a6b616eacd1291926307f4d339`. Revalidar manifests/plataforma no PR usando as páginas de [Node](https://hub.docker.com/_/node/tags), [Chatwoot](https://hub.docker.com/r/chatwoot/chatwoot/tags), [Evolution](https://hub.docker.com/r/evoapicloud/evolution-api/tags).
- **ASSUMED — runtime:** imagens efetivas/digests anteriores, patch PG/Redis, extensions, plugins instalados, recursos/filas/volume sizes, cron/off-host e estado real de branch protection. Nenhum comando Docker nem probe live foi feito por instrução do usuário. `.env` não foi inspecionado: variáveis externas podem alterar o comportamento inventariado.
- **ASSUMED — Squid:** catálogo/README divergiram sobre destino de latest (README7.2-beta, API aponta digest também associado6.6-beta). Não escolher versão a partir desse alias. Release7.7 é comprovada; build, entrypoint e ACL foram implementados e testados na W7a (contrato abaixo). Não declarar a proteção SSRF funcional só pela existência do container: rodar `scripts/test-ssrf-proxy.sh`.
- **ASSUMED — cobertura upstream:** notas consultadas nos marcos intermediários e changelogs/guia de migração; não foi feita auditoria integral de cada commit ou patch desde todas as versões flutuantes. Autoheal não oferece release notes formais; patches finais Promtail não mudam seu EOL; latest Azure plugin no Marketplace não confirmado. Material upstream de branches `main/master/latest` deve ser congelado na tag de destino no PR.
- **ASSUMED — compatibilidade:** restore com bases reais, orçamento RAM/CPU (~31GB compartilhados), clientes Redis8, lock/toolchain TS7/ts-node, API interna Dify e tasks beat, sessão WhatsApp, callbacks Meta, rota Worker e migração state Cloudflare. Esses itens têm testes/gates nas ondas; não são autorizados por ausência de erro na leitura estática.
- Cloudflare4→5 é migração de recursos/state: [guia na tag5.26.0](https://github.com/cloudflare/terraform-provider-cloudflare/blob/v5.26.0/templates/guides/version-5-upgrade.md) renomeia `cloudflare_record` para `cloudflare_dns_record` e altera schemas. Manter ID do túnel e tokens; abortar plan com replacement/destruction. Descobrir raiz/state ativos sem acionar módulos GCP descomissionados.
- **Liberação:** cada PR precisa pins/digests exatos, arquivos/config reproduzíveis, changelog/diff pertinente fechado, backup/restauração demonstrados, quatro checks verdes, apply restrito, validação real e saúde/observação registradas. Uma lacuna bloqueante mantém apenas aquela onda pendente; não substituir por “compatível” sem evidência. Este documento é plano, não relatório de upgrades executados.

## 6. Ajustes pós-revisão (`@rev`/`@sec` na PR #220) — prevalecem sobre as seções acima

1. **Alpine sai da W7a:** o bump de `alpine` (init do Dify + `BACKUP_HELPER_IMAGE`) vira uma onda própria pequena (**W6b**), para a W7b (Dify) não ficar bloqueada pelo build reproduzível do Squid.
2. **Node do CI só muda na W9:** a W0a mantém Node 22 no CI; a troca para 24 acontece junto com as imagens (`middleware` node:22, `self-healing` node:20), para o CI não testar um runtime que não roda em produção.
3. **W13/W14 precisam atualizar a detecção do container do Postgres:** `scripts/run-stack.sh:124` (restore) e `scripts/backfill-contact-dify-conversations.sh:73` localizam o container pela imagem exata `pgvector/pgvector:pg16`, sem fallback. Trocar para o nome do serviço/container (como `backup-host.sh:126` já faz) **antes** de mudar a imagem.
4. **W2b (Alloy):** parar o Promtail **antes** de removê-lo do compose (`dc stop promtail` falha quando o serviço já não existe no merge). Não rodar `run-stack.sh up` (`--remove-orphans`) até a validação acabar, porque ele apagaria o container legado.
5. **Backup de volumes extras por onda:** usar override pontual (`BACKUP_VOLUME_SUFFIXES=... scripts/backup-host.sh`) em vez de adicionar Loki/Tempo/Prometheus/Redis ao default diário, que passaria a exigi-los todas as noites.
6. **W7b (Dify):** colocar `MIGRATION_ENABLED=false` no `dify-api` durante o cutover, para o boot não re-executar a migração depois do `flask db upgrade` avulso. Com `--no-deps`, o `dify-init` não roda, então fazer o `chown` de storage explicitamente, se necessário.
7. **AGENTS.md desatualizado** sobre a cobertura de volumes do `backup-host.sh`: corrigir em PR de follow-up.
8. **SSRF (Squid) sem ACL:** tratado agora na issue #222, fora das ondas.

### W4b — Tempo 3.0 operational contract

Sources pinned to the deployed tag: [migration](https://github.com/grafana/tempo/blob/v3.0.3/docs/sources/tempo/set-up-for-tracing/setup-tempo/migrate-to-3.md),
[configuration](https://github.com/grafana/tempo/blob/v3.0.3/docs/sources/tempo/configuration/_index.md),
[module wiring](https://github.com/grafana/tempo/blob/v3.0.3/cmd/tempo/app/modules.go).

- `target: all` explicitly selects Kafka-free monolithic mode. No command or port
  changes: OTLP binds `0.0.0.0:4317/4318`, API `3200`, internal gRPC `9095`.
  Collector exporter, Grafana datasource UID/URL, logs→traces links and HTTP
  streaming remain unchanged. The sibling `/api/echo` probe is retained; storage
  and ingest correctness are separately tested, not inferred from this liveness probe.
- `ingester.max_block_duration` moves to `live_store.max_block_duration: 30s` (the 3.0 default, tighter than the old
  five-minute upper bound; more frequent, smaller blocks).
  `compactor` is removed: the in-process backend scheduler creates maintenance
  jobs and backend worker executes compaction/retention on the local backend.
  Scheduler provider compaction settings and worker compaction settings retain
  `block_retention: 120h`; retention scheduling defaults to hourly (expiry is
  asynchronous, with compacted-block cleanup grace). The regression checks both
  modules start and the retention provider runs, not a five-day expiry simulation.
- `query_frontend.query_end_cutoff: 0s` disables the new default 30-second search
  exclusion; `live_store.fail_on_high_lag: false` pairs with that setting in the
  synchronous Kafka-free mode. Immediate TraceQL search remains available.
- Keep vParquet4, `/var/tempo/blocks`, the `/var/tempo` volume and `user: "0"`.
  Live-store WAL is explicitly `/var/tempo/live-store/traces`, with shutdown markers
  under `/var/tempo/live-store/shutdown-marker`; scheduler work cache is `/var/tempo`.
  The legacy `storage.trace.wal.path` remains but is not the new live-store WAL.
  The 3.x `/flush` endpoint is removed; shutdown cuts traces to WAL; block completion may be cancelled and replayed on restart.
  Drain/flush 2.x before switching: do not assume its pending WAL is migrated.
  Live-store replays its own WAL on restart; accepted spans still in memory can be
  lost on a crash before WAL flush (default idle 5s / maximum live 30s, plus sweep).
  There is no Kafka durability layer. Memory now includes live-store buffers,
  concurrent queries and backend-worker compaction: the existing 768MiB limit is
  unchanged and needs operator load/OOM monitoring; the former 2.x RSS is no sizing proof.
- Trace IDs in vParquet4+ blocks remain readable. TraceQL metrics only read RF1
  blocks; historical RF3 data from 2.x is not retroactively available to metrics queries.
- Future live apply (not part of this worktree task): coordinate an ingest pause,
  flush/drain and stop only Tempo; take and verify a **cold** `tempo-data` archive
  off-host together with the 2.10.8 pin/config. Use a wave-specific backup override,
  never change daily backup defaults or freshness gates. With the established
  production Compose chain, run `docker compose up -d --no-deps tempo`. Verify old
  and new trace IDs, new TraceQL search, `/api/echo`, maintenance services/logs and
  health; resume ingestion and monitor memory. No in-place downgrade: stop Tempo,
  restore the cold volume backup and saved 2.10.8 config/pin, then recreate only Tempo.
  Traces accepted after the backup are not recovered by that rollback.
- CI uses one synthetic throwaway volume through 2.6.1 → 2.10.8 → compose-pinned
  3.x; pulls precede a 180s deadline plus 15s cleanup grace. No browser regression
  is needed for this internal storage/OTLP change. Production apply and live
  validation must be performed separately by the operator.


### W5a — Redis 7.2 patch operational contract

Compose pins `redis:7.2.16-alpine@sha256:29e8589c3f9ba699b5f7aa4b3c7733c58852a3626439e619aa0ee78de08c6ca0`
(index resolved with `docker buildx imagetools inspect`). The historical CI/R1 pin is
`redis:7.2.4-alpine@sha256:c8bb255c3559b3e458766db810aa7b3c7af1235b204cfdb304e79ff388fe1a5a`.
W5b remains a separate, conditional wave.

Reviewed [all 7.2.5–7.2.16 release notes](https://github.com/redis/redis/blob/7.2.16/00-RELEASENOTES):
security fixes cover Lua RCE, ACL bypass/DoS, unauthenticated output-buffer growth,
HyperLogLog, error-reply injection, RESTORE/stream and blocked-client use-after-free,
TLS connection handling, and redis-check-aof. Relevant correctness fixes include
blocking-command timeout reset (7.2.5), AOF manifest detection in redis-check-aof
(7.2.5), and stream lag accounting (7.2.7/7.2.9). These patches announce no new
AOF/RDB format or configuration-default change requiring service changes; RDB v11
was introduced in 7.2.0, before both endpoints. Keep requirepass, appendonly,
150mb maxmemory, noeviction, 256m mem_limit and healthcheck unchanged.

`scripts/tests/test-redis.sh` extracts the service command/memory/image from Compose,
uses runtime-generated credentials and isolated disposable resources, and checks
DBs 0/1/2, all broker data types, exact expiration timestamps, populated RDB/AOF
persistence, authentication, client reconnection and a second restart. Pulls precede
the <120s bounded test/cleanup. Internal broker regression: Playwright N/A.
The root/CI Compose files inherit the shared pin. Historical logs remain historical.
`health-check-all.sh` checks Redis service health and memory; `run-stack.sh` uses the
shared Compose definition; `backup-host.sh` supports a one-off volume override and
has no Redis-version dependency. No daily backup defaults or freshness gates change.

Operator-only apply (use the `dc` function in section 3; coordinate the outage):

1. Pass CI/reviews, pre-pull `dc pull redis`, record old pin and queue/key counts.
   Block external webhooks/UI/API ingress and pause external scheduled producers.
   Stop `autoheal` during maintenance. Stop `self-healing-agent`, `middleware`, and
   `evolution-api` (the first two are indirect API producers, not Redis clients).
   Let in-flight API work settle, then stop `chatwoot-rails` and `dify-api`.
   Keep `chatwoot-init` stopped/completed: it also has REDIS_URL, but is a one-shot.
2. Drain with `chatwoot-sidekiq`, `dify-worker`, and `dify-plugin-daemon` still up.
   Check Sidekiq Queue sizes and ProcessSet busy counts via `sidekiq/api` (DB1);
   inspect Celery `active`, `reserved`, `scheduled`, and `active_queues` via
   `celery -A app.celery inspect` in `dify-worker` (DB0). Require no active/reserved
   tasks and ready queues empty, including Celery priority queue lists. Inventory
   Sidekiq retry/scheduled sets and Celery future ETA tasks; do not purge them to
   obtain zero. Wait for or deliberately preserve future work with no task in flight.
   Gracefully stop `chatwoot-sidekiq`, `dify-worker`, then `dify-plugin-daemon` with
   a timeout sufficient for completion; abort on forced termination. Confirm all
   named clients stopped, remaining queues/key counts stable and `CLIENT LIST`
   contains only operator probes. No separate beat service exists in this chain.
3. With clients stopped, issue an authenticated `SAVE` using `REDISCLI_AUTH`
   supplied securely by the operator (never print the password), then `dc stop redis`.
   Do **not** rely on `SHUTDOWN SAVE` alone: the service has `restart: unless-stopped`,
   so Docker restarts it after a clean exit and the archive would be taken from a live
   volume. Confirm state `exited` with exit code 0 before the backup. Cold-backup
   `chat-services_redis-data`, including
   dump.rdb and the entire appendonlydir/manifest, with the one-off override:
   `BACKUP_VOLUME_SUFFIXES="chatwoot-storage dify-api-storage evolution-instances grafana-data redis-data" scripts/backup-host.sh`.
   Verify the exact volume selected, exit status, archive contents/integrity and
   off-host copy; do not add redis-data to daily defaults.
4. `dc up -d --no-deps redis`. Check authenticated PING, unauthenticated NOAUTH,
   `INFO persistence` loading=0, aof_enabled=1, aof_last_write_status=ok, and
   `CONFIG GET maxmemory maxmemory-policy` = 157286400/noeviction. Compare preserved
   queue/key counts and expirations before reopening writers.
5. Start stopped services in dependency order: `dc start dify-plugin-daemon`, then
   `dc start dify-worker chatwoot-sidekiq`, then `dc start dify-api chatwoot-rails`,
   then `dc start evolution-api middleware self-healing-agent`. Confirm health,
   resume `autoheal` and ingress, and verify real Sidekiq/Celery tasks reach terminal
   success, reconnects succeed, and no auth/AOF/OOM or rising backlog appears.
   Run section 3 live validation/health checks and observe a load/backup cycle.
6. R1 rollback: quiesce the same writers again, stop Redis cleanly, archive failed
   post-upgrade state, restore the cold redis-data archive into an empty replacement
   volume (never overlay AOF files), reinstate the immutable 7.2.4 pin above, recreate
   only Redis with `--no-deps`, and repeat startup/verification. Reconcile all writes
   since the backup before reopening traffic. Never touch the Postgres volume.

### W6 — Evolution 2.3.7 operational contract

Compose pins `evoapicloud/evolution-api:v2.3.7@sha256:1bd8afc4a6cf48822e6cf02469aeae7bd35a12a6b616eacd1291926307f4d339`.
The CI/R1 old pin is `evoapicloud/evolution-api:v2.1.1@sha256:c7d72f0795341498f1d61751b8f35ab48037683ee50450a445b0079c1509c25e`.
Both multi-platform indexes were reverified with `docker buildx imagetools inspect`;
the registry tag is **v2.3.7**, not `2.3.7` (the latter does not exist).

Reviewed [2.2.0 notes including 2.1.2](https://github.com/evolution-foundation/evolution-api/releases/tag/2.2.0),
[2.2.1](https://github.com/evolution-foundation/evolution-api/releases/tag/2.2.1),
[2.2.2](https://github.com/evolution-foundation/evolution-api/releases/tag/2.2.2),
[2.2.3](https://github.com/evolution-foundation/evolution-api/releases/tag/2.2.3),
and [2.3.0](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.0),
[2.3.1](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.1),
[2.3.2](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.2),
[2.3.3](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.3),
[2.3.4](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.4),
[2.3.5](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.5),
[2.3.6](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.6),
[2.3.7](https://github.com/evolution-foundation/evolution-api/releases/tag/2.3.7).
These cover Prisma/index migrations, webhook retries, cache fixes, Chatwoot media
and contact deduplication, LID/JID handling, Baileys 7.0.0-rc.9, and shell-injection
and unauthenticated `/assets` traversal fixes. 2.3.1 removes
`CONFIG_SESSION_PHONE_VERSION`; we do not supply it.

Configuration evidence: [2.3.7 example](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/.env.example),
[parser](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/config/env.config.ts),
[Dockerfile](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/Dockerfile).
The upstream `2.1.1`/`v2.1.1` source tags are unavailable; the comparison uses
[version-2.1.1 source at 5ebebbf](https://github.com/evolution-foundation/evolution-api/tree/5ebebbf211b84f09315eb20e416ad5e5b8c6ef37)
and the immutable old image in the migration test.

- Add only `TELEMETRY_ENABLED=false`: the new parser defaults it on, and
  [sendTelemetry](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/utils/sendTelemetry.ts)
  posts route/version/timestamp to `https://log.evolution-api.com/telemetry`.
  No new operator key; `.env.production.example` is unchanged.
- Both Dockerfiles bake `.env.example` into the image; dotenv supplies unset values.
  Redis remains enabled, prefix `evolution`, TTL 604800, save-instances false,
  local cache false. `DATABASE_CONNECTION_CLIENT_NAME=evolution_exchange` and
  `DATABASE_SAVE_DATA_{INSTANCE,NEW_MESSAGE,CONTACTS,CHATS,LABELS,HISTORIC}`,
  `DATABASE_SAVE_MESSAGE_UPDATE`, `DATABASE_SAVE_IS_ON_WHATSAPP` remain true
  (WhatsApp lookup retention seven days). Keep those defaults; no redundant env
  overrides. Our explicit URI keeps Redis DB2 and Postgres `evolution`/public,
  overriding the new example's different database/schema. Never change the client
  name casually: startup filters persisted instances by it.
- `DATABASE_DELETE_MESSAGE=true` now selects logical deletion. Retain it: the old
  code recorded deletion events without physically deleting message rows; setting
  false would introduce physical deletion. Actual WhatsApp deletion is not tested.
  `CHATWOOT_ENABLED=false` remains the bundled default: no existing integration
  or session is configured. Enabling/configuring the WhatsApp→Chatwoot bridge is a
  separate operator prerequisite before claiming that product path works.
- Keep HTTP 8080, 512MiB limit and `/evolution/instances`. Both images default to root; no ownership migration.
  Node moves 20→24. The manager remains at `/manager` (new manager assets), enabled
  unless `SERVER_DISABLE_MANAGER=true`; its API still requires `apikey`.
  The [router](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/src/api/routes/index.router.ts)
  now fetches the latest WhatsApp Web version from the internet on every `GET /`.
  The container healthcheck therefore moves to an authenticated
  `/instance/fetchInstances` (router, `apikey` guard and Postgres, no outbound
  call), so an egress outage cannot mark it unhealthy and trigger autoheal. The key
  is expanded inside the container, never stored in the healthcheck definition.
  `GET /` stays public and is still what external probes see; expect it to be slow
  when egress is degraded. The test uses a new private bridge with egress,
  no published ports, no real WhatsApp credentials or connection.
- The [entrypoint](https://github.com/evolution-foundation/evolution-api/blob/2.3.7/Docker/scripts/deploy_database.sh)
  runs Prisma deploy and generate before serving HTTP, exiting on failure.
  Migrations are forward-only: an old image against the upgraded DB is not R1.
  Keep autoheal stopped throughout migration and readiness validation.
- `middleware/src/handlers/admin.ts` removed Evolution provisioning, discovery and
  status calls in #31; `config.ts` only retains optional API key/base URL fields.
  There are no active middleware Evolution routes/payloads to adapt. Existing admin
  tests/Playwright fixtures use these configuration fields, not a version-specific
  Evolution response. CI overrides and root Compose inherit the pin; no version
  assertion changes are needed. Historical logs/plans remain historical; the
  AGENTS.md statement “v2.1+” still holds.

`scripts/tests/test-evolution.sh` derives image/environment/healthcheck from Compose,
uses generated credentials and random disposable Postgres/Redis/instances resources,
boots the pinned old image to its 42 migrations, and creates an `EVOLUTION` instance
(no Baileys connection), settings and a disabled webhook through authenticated HTTP.
It checks preserved identity/configuration, version, rejected unauthenticated access,
completed additional migrations, the real healthcheck, and unchanged migration IDs/
checksums/timestamps after a new-image restart. Pulls precede the 210s deadline plus
20s kill/cleanup allowance. Logs/responses are not dumped because upstream may print
credentials. Two completed local runs passed in 26.2s and 26.7s after pulls,
with 42→57 migrations and successful cleanup. The earlier no-egress experiment
exited with SIGSEGV in the old image after migration; its cause was not established.
This is an internal API/schema regression; Playwright N/A.

Operator-only apply (future work; use section 3's `dc`, coordinate the outage):

1. Pass the four CI gates/reviews, record the old immutable pin/config, and
   `dc pull evolution-api`. Block Evolution ingress/provisioning writers. Run
   `dc stop autoheal evolution-api`; confirm Evolution is exited before backup.
   Do not stop/recreate Postgres or Redis. The operator-verified baseline is 42
   migrations ending `20240906202019_add_headers_on_webhook_config`, no instances
   or other table rows, empty Redis DB2 and empty instances volume; if that changes,
   preserve the new session/Redis state before proceeding.
2. Take a fresh DB dump and **cold** instances archive using the existing backup
   script; its default `BACKUP_VOLUME_SUFFIXES` already includes
   `evolution-instances`, so a plain `scripts/backup-host.sh` run is enough.
   This runs `pg_dump --clean --if-exists` for DB `evolution`; verify its dump is
   present, `gzip -t` passes, and the migration/table counts match the baseline.
   Verify the archive selected `chat-services_evolution-instances`, its tar integrity
   and off-host copy. Save exact paths for R1; do not use June's historical dumps.
   If Redis DB2 is no longer empty, stop here and arrange an instance-scoped
   DUMP/PTTL backup/restore with writers stopped; never FLUSHALL or restore the
   shared Redis volume over Chatwoot/Dify data.
3. `dc up -d --no-deps evolution-api`. Wait for Prisma deploy/generate success and
   HTTP readiness; inspect logs privately (startup may contain a database URI).
   Query DB `evolution`: `SELECT count(*) FROM "_prisma_migrations";` must exceed
   42, and `SELECT count(*) FROM "_prisma_migrations" WHERE finished_at IS NULL OR
   rolled_back_at IS NOT NULL;` must be zero. Compare instance/config counts.
   Verify `/` reports 2.3.7, the Compose healthcheck succeeds, authenticated
   `/instance/fetchInstances` works and the same request without `apikey` is 401.
   Supply the existing API key securely; do not paste credentials or responses into
   public logs/issues. Confirm the image digest and no OOM/restart loop.
4. `dc restart evolution-api`, repeat readiness/auth/data checks and require no
   new/failed migration rows. Run `scripts/run-stack.sh validate` and
   `scripts/health-check-all.sh`, then `dc start autoheal` and reopen ingress.
   Observe one load/backup cycle, including 512MiB memory headroom.
5. **R1:** block writers again, `dc stop autoheal evolution-api`, archive the failed
   post-upgrade DB/volume for reconciliation. Restore only DB `evolution` from the
   fresh dump: terminate its connections, drop/recreate **that DB only** in the
   existing Postgres container, then
   `gzip -dc "$EVOLUTION_DUMP" | dc exec -T postgres psql -v ON_ERROR_STOP=1 -U postgres -d evolution`
   with `set -o pipefail`. Restore the matching cold instances archive into an empty
   volume, never overlay files: with Evolution stopped and removed, set the failed
   `chat-services_evolution-instances` aside by archiving it, recreate it empty
   under the same name (Compose binds it by name) and extract the archive into it; restore only Evolution Redis keys if
   backed up. Reinstate the old v2.1.1 tag@digest above and old config/volume binding,
   `dc up -d --no-deps evolution-api`, verify the 42-migration baseline, data, auth
   and health, then resume autoheal/ingress. No global restore, shared Postgres
   recreation or shared Redis flush. Writes after backup require reconciliation.

Production was not touched by this worktree task. No WhatsApp instance exists, so
Meta/Baileys session establishment/reconnection, real webhook delivery into Chatwoot,
text/audio/document/media inbound/outbound and contact deduplication **cannot be
validated live** now. The synthetic pass is not evidence for those flows; validate
terminal sent/delivered states through Chatwoot when an operator provisions a real
instance. Hosted CI, production apply, restore rehearsal and observation remain
operator release gates.

### W6b — Alpine 3.24.2 operational contract

All four helpers (Dify init, backup default, Tempo and Collector probes) use
`alpine:3.24.2@sha256:294b683cb724975bec92580e1e685676bd4b50bda910ddb8c51d4cabeaec77e6`.
Verified with `docker buildx imagetools inspect` on 2026-10-02: the `3.24` tag
resolves to the same OCI index; [upstream releases](https://alpinelinux.org/releases/)
list 3.24.2 as the newest 3.24 patch. `BACKUP_HELPER_IMAGE` remains env-overridable.

BusyBox moves from 1.36.1 (3.19.9/3.20.10) to 1.37.0. The relevant help/flags
are unchanged: `tar czf - -C /data .`, `chown -R 1001:1001`, and HTTP
`wget -qO- -T 2/5`. Synthetic old/new fixtures confirm archive metadata/content
and recursive ownership/mode preservation; a second init is idempotent.
The actual Compose init invokes only chown (no mkdir/sh wrapper).
BusyBox tar extraction on both old and new images leaves symlinks root-owned,
although the archive records their original UID/GID. The regression restores
with BusyBox tar (including volume-root metadata) plus `docker cp -a` (symlink
ownership) and compares names, sizes, modes, UID/GID, link targets and contents.
This is an existing restore limitation, not lost backup metadata.
`scripts/tests/test-alpine-helpers.sh` derives the init from Compose and extracts
the backup tar invocation; pulls precede its <60s test/cleanup deadline.
The existing backup size-guard suite remains separate. Playwright N/A: internal
filesystem helpers; the Tempo/Collector suites exercise the changed wget probes.

Operator sequence after CI/review: no running service is recreated for this wave.
Dify init is one-shot and picks up the pin on the next normal Dify `up` (not a
`--no-deps` service recreation); do not rerun recursive chown live just for this bump.
The backup helper is pulled on the next backup run if absent locally. Manually run
`scripts/backup-host.sh`, require success, check archive integrity/listings and
UID/GID/modes/link targets, `.last-success` coverage and the off-host copy.
Rollback restores the previous references: Dify `alpine:3.19`, backup default
`alpine:3.20`, and both probes
`alpine:3.21@sha256:ce64758a109eb420d874a118f87920e625e12d3634e03b4a5573fd9f6e5d3507`;
the first two were unpinned, so retain their pre-change image IDs for exact rollback.
Production backup/apply/validation is operator-only and was not run in this worktree.

### W7a — Squid 7.7 operational contract

No published `ubuntu/squid` image carries Squid 7.x, and Alpine 3.24 packages
7.6 rather than 7.7, so `deploy/squid/Dockerfile` builds it. Provenance:

- Source: `squid-7.7.tar.xz` from the upstream GitHub release `SQUID_7_7`
  (published 2026-08-24), SHA-256
  `e3bd613b91b1c498ec2992276063342a85cd6edddd5521294e04f44bc055da9b`. The value
  matches the asset digest GitHub reports for that release.
- Signature: the detached `.asc` is verified during the build against
  `deploy/squid/release-key.asc` (public key, fingerprint
  `29B4 B1F7 CE03 D1B1 DED2 2F30 28F8 5029 FEF6 E865`, upstream release signing key).
  The build fails if either the checksum or the signature does not verify.
- Base: `alpine:3.24.2` by digest for both stages (musl; nothing in our config
  needs glibc). Build tools come from `apk` at build time and are not version
  pinned, so the image is reproducible in source and behaviour, not bit for bit.
- Configure: forward proxy only. Disabled: auth, every helper class, disk
  stores and disk I/O, ICAP, WCCP, SNMP, HTCP, EUI, QoS marking, and all TLS
  libraries (CONNECT is an opaque tunnel; nothing is bumped).
- Runtime image: about 25 MB, `libstdc++` plus the stripped binary, error pages
  and `mime.conf`; runs as uid/gid 10001, static entrypoint, no shell templating.

`deploy/squid/squid.conf` keeps every ACL unchanged; `squid -k parse` passes on
7.7 with no removed or renamed directive. One addition, valid for 6.x and 7.x:
`max_filedescriptors 4096`. Squid sizes its descriptor tables from
`RLIMIT_NOFILE`, which Docker sets to about a million. Measured without the cap:
~125 MiB resident while idle on 7.7, and ~93 MiB anonymous memory on the live
6.13 container, which had hit its 128 MiB cgroup limit hundreds of times since
boot. With the cap, 7.7 stays at ~13 MiB idle, after the ACL suite and under 16
concurrent CONNECT tunnels. The mount stays read-only, so the config can change
without a rebuild.

Compose names the image `nexaduo/squid:7.7-local` with a `build:` context and
no `pull_policy: build`: `up` builds only when the tag is missing, so a boot
after an engine restart never needs the network. Bump the tag whenever the
Dockerfile changes. CI builds it explicitly before starting the stack.

`scripts/tests/test-squid.sh` builds the image and a TLS fixture, then on two
internal throwaway networks asserts the version, a non-root PID 1, `squid -k
parse`, the full `scripts/test-ssrf-proxy.sh` suite (the same script CI and the
operator run against the real stack), 16 concurrent tunnels and a peak RSS
under 64 MiB. About 10s after the builds; a cold build takes 2 to 5 minutes.
Playwright N/A: proxy policy is not observable in the web flow.

Operator-only apply (use section 3's `dc`, from the main checkout):

1. Pass the four CI gates and reviews. Record the running image reference for
   R0. `dc build dify-ssrf-proxy`; confirm `squid -v` in the new image says 7.7.
2. `dc up -d --no-deps dify-ssrf-proxy`. Nothing else is recreated; the proxy
   holds no state. Dify HTTP tools and sandbox egress fail for the few seconds
   it is down.
3. Verify: `squid -v` reports 7.7, PID 1 is not root, memory well under the
   128 MiB limit, no restart loop; `scripts/test-ssrf-proxy.sh` with the
   production `COMPOSE_FILE` chain; then `scripts/run-stack.sh validate` and
   `scripts/health-check-all.sh`. A Dify HTTP tool call and the handoff tool
   are only exercised by real conversations: watch the proxy and middleware
   logs on the next one.
4. **R0:** set the image back to
   `ubuntu/squid:6.6-24.04_beta@sha256:6a097f68bae708cedbabd6188d68c7e2e7a38cedd05a176e1cc0ba29e3bbe029`,
   drop the `build:` line, and `dc up -d --no-deps dify-ssrf-proxy`. The
   `max_filedescriptors` line is valid on 6.13 and should stay.

### W7b — Dify 1.17.1 operational contract

Pins (index digests, verified with `docker buildx imagetools inspect`):

- `langgenius/dify-api:1.17.1@sha256:ceede5b903afaa20348f7ad80ebf847379dc56d886a99b9ec6a08913dacd7732` (api and worker)
- `langgenius/dify-web:1.17.1@sha256:6353fe8e04481aaef873ef7317507bfa9ac862572118fd037563a71bff9f4d08`
- `langgenius/dify-sandbox:0.2.15@sha256:750e1111426ef31a9217b81c98cccfb750f17b182af3221102e420afa9f0928e`
- `langgenius/dify-plugin-daemon:0.6.10-local@sha256:34412a22d1e1d1a6c73727fef88cffbcdd9be7a21bf9ad3076b4bf5c1b88fd9b`

Reviewed the upstream release notes for 1.14.0, 1.14.1, 1.14.2, 1.15.0, 1.16.0,
1.16.1, 1.17.0 and [1.17.1](https://github.com/langgenius/dify/releases/tag/1.17.1),
and the upstream `docker/docker-compose.yaml` at both tags. What applies here:

- **Migrations are forward-only.** 1.17.1 includes the legacy model type
  migration (`5578e028b2f2`), whose downgrade is a no-op. Production holds two
  `text-generation` rows that it rewrites to `llm`. No manual `flask
  data-migrate` step is needed from 1.17.1 on. Rollback is restore, not downgrade.
- **Weaviate ladder does not apply**: this stack uses pgvector.
- **Agent App (Beta) stays off.** Since 1.16 it is on by default and needs two
  new services (`agent_backend`, a shell sandbox) plus a second proxy. None is
  added; `NEXT_PUBLIC_ENABLE_AGENT_V2=false` hides it in the web UI. The API and
  worker boot and serve existing apps without `agent_backend` (rehearsed).
  Collaboration (`api_websocket`) is also left off, its upstream default.
- **No beat container**, as before the upgrade: scheduled triggers and periodic
  clean-up tasks do not run. Unchanged behaviour, recorded here as a known gap.
- **Environment.** `dify-api` and `dify-worker` now share one block
  (`x-dify-app-env`). Before, the worker only had database and broker settings
  and used in-image defaults for the vector store, sandbox and plugin daemon.
  `INNER_API_KEY_FOR_PLUGIN` is now set from `DIFY_PLUGIN_DIFY_INNER_API_KEY`:
  it was unset, so the API kept the in-image default while the plugin daemon
  sent the configured key (compared by hash on the live 1.13.3 containers: they
  differed). No new operator key; `.env.production.example` is unchanged.
- **Service API contract used by this repo is unchanged**: `POST
  /v1/chat-messages` in streaming mode still emits `agent_message`,
  `agent_thought` and `message_end` (middleware), and `POST /v1/workflows/run`
  in blocking mode returns `data.outputs` (self-healing). Both were exercised.
- **Console auth**: session cookies are `Secure` and requests need the
  `X-CSRF-Token` header. Browsers through the tunnel are unaffected; scripts
  talking plain HTTP to the API must send the cookies themselves.

**Rehearsal on a copy of production data.** `scripts/rehearse-dify-upgrade.sh`
restores the newest `dify` and `dify_plugin` dumps into a throwaway Postgres,
copies both storage volumes (the live plugin volume is mounted read-only), and
runs the pinned images on a private network with Traefik/autoheal labels reset
and the log driver off, so the live proxy, autoheal and Loki never see it. It
runs the cutover's migration command, boots everything, and checks: Alembic
revision moved and is stable on a second boot, row counts unchanged, no legacy
model types left, inner API key equal between API and plugin daemon, console
login (password reset in the copy only) listing apps, an active model provider
and the installed plugins. It then creates a text document in the first
knowledge base, waits for the worker to index it and retrieves it by keyword.
With `--invoke` it sends one message or workflow run per app that has a service
API token, using the copied credentials against the real model provider. The
copy has internet egress and carries the apps' real tool configuration, so
`--invoke` refuses to run when an app has non-builtin tools or HTTP nodes
unless they were reviewed (`--allow-external-tools`). Today the apps only use
the builtin `current_time` tool.

Result on 2026-10-02 against the 03:34 dumps: migration in 15 to 18 seconds
(`6b5f9f8b1a2c` to `c3f1a9b2e6d4`); 12 table counts and both plugin counts
unchanged; console lists 3 apps, 1 active provider, 2 plugins; a document was
indexed by the worker and retrieved (the knowledge base is in `economy`
keyword mode and no embedding model is configured, so pgvector indexing is
**not** exercised and stays unproven on either version); the agent-chat
app answered and the self-healing workflow returned `root_cause`, `severity`,
`suggested_fix`; no restart or OOM; api ~505 MiB, worker ~495 to 865 MiB,
plugin daemon ~240 MiB, all inside their limits. About 95 to 115 seconds end
to end. There is no CI upgrade fixture: CI boots the pinned version from an
empty database (the fresh-install path), and the upgrade path is covered by
this rehearsal on real data, which a synthetic fixture cannot represent.
Playwright: the existing Stage 1 suite already probes `/console/api/setup` and
the Dify edge routes; no new web flow is introduced.

Operator-only apply (use section 3's `dc`, from the main checkout):

1. Four CI gates and both reviews pass. `dc pull dify-api dify-web dify-sandbox
   dify-plugin-daemon`. Run `scripts/rehearse-dify-upgrade.sh --invoke` on the
   merged commit; do not continue unless it passes.
2. Turn the kill switch on (`docs/dify-kill-switch.md`) and confirm the row, so
   the middleware stops calling Dify and messages stay in Chatwoot.
   `dc stop autoheal`, then `dc stop dify-web dify-api dify-worker
   dify-plugin-daemon`. Never stop or recreate Postgres or Redis.
3. Back up with the consumers stopped, adding the plugin volume to the default
   set: `BACKUP_VOLUME_SUFFIXES="chatwoot-storage dify-api-storage
   evolution-instances grafana-data dify-plugin-storage" scripts/backup-host.sh`.
   Verify `gzip -t` on the `dify` and `dify_plugin` dumps and on both Dify
   volume archives; note their paths for R1. Record the row counts and the
   Alembic revision.
4. Migrate once: `dc run --rm --no-deps -l traefik.enable=false -l
   autoheal=false -e MODE=migration -e MIGRATION_ENABLED=true dify-api`. The
   labels keep the one-off container out of the live Traefik router and away
   from autoheal. It must exit 0 and the revision must move.
5. `dc up -d --no-deps dify-sandbox dify-plugin-daemon`, wait for
   `http://dify-plugin-daemon:5002/health/check`, then `dc up -d --no-deps
   dify-api dify-worker dify-web`. The API re-runs the migration command on
   boot; it must be a no-op. With `--no-deps`, `dify-init` does not run: storage
   ownership is already uid 1001 and is not touched.
6. Verify: three services healthy, revision unchanged since step 4, row counts
   equal to step 3, no legacy model types, inner API key equal and non-empty
   on API and daemon, no restart loop or OOM. Send one message through the service API to
   prove credentials and the plugin runtime in production. Then turn the kill
   switch off, `dc start autoheal`, `scripts/run-stack.sh validate` and
   `scripts/health-check-all.sh`. Console login through the tunnel and the next
   real conversation (reply, memory, handoff) are operator checks.
7. **R1:** kill switch on, stop the four Dify services and autoheal. Archive
   the failed state. Drop and recreate **only** the `dify` and `dify_plugin`
   databases in the existing Postgres and restore the step 3 dumps with
   `ON_ERROR_STOP=1`; empty and restore both Dify volumes from their archives;
   revert the compose change (pins 1.13.3 / 0.2.14 / 0.5.3-local); `dc up -d
   --no-deps` the same services; verify; kill switch off. Redis is not
   restored: Dify keeps only queue and cache state there, and with the workers
   stopped before the backup no job is pending. Writes made after the backup
   are lost and must be reconciled from Chatwoot.

### W8 — Chatwoot 4.18.0-ce operational contract

All three services (`chatwoot-init`, `chatwoot-rails`, `chatwoot-sidekiq`) pin
`chatwoot/chatwoot:v4.18.0-ce@sha256:faaa58a911cda8f2ab9d717ddf8ca4332163b07da4c5da10711d896e5d667442`
(index digest, verified with `docker buildx imagetools inspect`). Reviewed the
upstream release notes for every release from 4.14.0 to
[4.18.0](https://github.com/chatwoot/chatwoot/releases/tag/v4.18.0) and read the
4.18.0 image where the notes were not specific. What applies here:

- **Webhooks go through SafeFetch and private addresses are refused** (since
  4.14; `lib/webhooks/trigger.rb`, `lib/safe_fetch.rb`). The Agent Bot endpoint
  is `http://middleware:4000/webhooks/chatwoot` on the Docker network. Without
  a change the bot goes silent and, because a failed bot delivery moves the
  conversation, every `pending` conversation is opened. The only switch 4.18 CE
  offers is `SAFE_FETCH_ALLOW_PRIVATE_NETWORK=true`, now set on rails and
  sidekiq. It is all-or-nothing: avatar and upload-by-URL fetches can reach
  private addresses too, as they could on 4.13, which had no SafeFetch.
  Tracked in #260 with the two narrower alternatives.
- **`chatwoot-public` is no longer mounted.** The named volume at `/app/public`
  held the 4.13 frontend assets and would have masked the 4.18 ones (under
  `vite/assets`, 122 of the 298 files of the new image were missing from the
  volume, and the Vite manifest differs). It contained exactly the
  4.13 image content and nothing written at runtime, so the mount is removed
  and assets are served from the image. The Docker volume itself is left on
  the host, untouched, for rollback.
- **Rails 7.1 to 7.2, Ruby 3.4.** `deploy/ai_agents.rb` still differs from
  upstream only by the table-existence guard (the upstream file is byte
  identical in 4.13 and 4.18). `deploy/assume_ssl.rb` is still needed: 4.18
  keeps `load_defaults 7.0` and does not wire `RAILS_ASSUME_SSL`. The entrypoint
  script and `config/initializers/omniauth.rb` are unchanged in place.
- **Migrations are forward-only** in practice: more than 50 migrations between
  schema `20260410092753` and `20260831000000`. Rollback is restore.
- **Agent Bot contract**: the bot's access token is still accepted by the
  messages API, and new conversations in a bot inbox still start `pending`.
  Deliveries are HMAC-signed with the bot's `secret`
  (`X-Chatwoot-Signature` over timestamp and body), which is what #252 needs.
- Not used here and not reviewed further: Captain (Enterprise), voice/calling,
  Dyte to RealtimeKit, Help Center, Intercom/Freshdesk imports. No new operator
  key; `.env.production.example` is unchanged.

**Rehearsal on a copy of production data.**
`scripts/rehearse-chatwoot-upgrade.sh` restores the newest `chatwoot` dump and
`chatwoot-storage` archive into throwaway resources on an **internal** network
(no egress: the copy carries real channel credentials), with Traefik/autoheal
labels reset and the log driver off. It runs the cutover's migration command
(`chatwoot-init`), boots rails and sidekiq, and checks: schema version stable
on boot, 16 table counts unchanged, `/api` reports the pinned version, the
login page references a Vite asset that the container actually serves (image
self-consistency; the rehearsal never mounts the old public volume), no
pending migration, `assume_ssl` applied, every attached blob present in storage
and one downloaded, a real incoming message in the bot inbox stays `pending`
and reaches a stand-in receiver at `middleware:4000`, the bot token posts a
reply through the API, and a negative control with the SafeFetch switch off is
blocked and opens the conversation.

Result on 2026-10-02 against the 05:09 dump: migration in 16 seconds; counts
unchanged (2 accounts, 16 conversations, 195 messages, 38 blobs); web, storage,
bot delivery, bot reply and negative control as expected; no restart or OOM;
rails ~465 MiB of 1536, sidekiq ~460 MiB of 2048. About 60 seconds end to end.
CI covers the fresh-install path and runs the Agent Bot producer contract
against the real middleware on the pinned image; the upgrade path is covered by
this rehearsal. Playwright: the existing Stage 1 suite probes the Chatwoot edge
route; login and onboarding flows are unchanged.

Operator-only apply (use section 3's `dc`, from the main checkout):

1. Four CI gates and both reviews pass. `dc pull chatwoot-rails`. Run
   `scripts/rehearse-chatwoot-upgrade.sh` on the merged commit; do not continue
   unless it passes.
2. Kill switch on (`docs/dify-kill-switch.md`). `dc stop autoheal`. Confirm the
   Sidekiq queues are empty, then `dc stop chatwoot-rails chatwoot-sidekiq`.
   While Chatwoot is down the edge answers 502 and Meta retries its webhooks
   later; keep the window short. Never stop or recreate Postgres or Redis.
3. `scripts/backup-host.sh` with the consumers stopped (the default set already
   includes `chatwoot-storage`). Verify `gzip -t` on the `chatwoot` dump and the
   storage archive; note their paths for R1. Record row counts and the schema
   version.
4. Migrate once: `dc run --rm --no-deps chatwoot-init`. It must exit 0.
5. `dc up -d --no-deps chatwoot-rails chatwoot-sidekiq`.
6. Verify: both healthy, `/api` reports 4.18.0, schema `20260831000000`, row
   counts equal to step 3, attached blobs readable, the login page's asset is
   served, `SafeFetch.allow_private_network?` true in rails and sidekiq, no
   restart loop or OOM. Kill switch off, `dc start autoheal`,
   `scripts/run-stack.sh validate`, `scripts/health-check-all.sh`. The bot is
   not probed with a synthetic conversation in production (it would call Dify
   and Meta for a fake contact): watch the next real message reach the
   middleware, be answered, and stay `sent` with a `source_id`. Login through
   the tunnel and attachments in the UI are operator checks.
7. **R1:** stop autoheal, rails and sidekiq. Archive the failed state. Drop and
   recreate **only** the `chatwoot` database in the existing Postgres and
   restore the step 3 dump with `ON_ERROR_STOP=1`; empty and restore
   `chatwoot-storage` from its archive; revert the compose change (4.13.0-ce
   pins, the `chatwoot-public` mounts **and** its top-level volume declaration;
   the volume is still on the host, so do not run `docker volume prune` until
   the upgrade is accepted);
   `dc up -d --no-deps chatwoot-rails chatwoot-sidekiq`; verify. Messages that
   arrived after the backup are lost in Chatwoot and must be recovered from the
   channels.

### W5b — Redis 8.10.2 operational contract

Compose pins `redis:8.10.2-alpine@sha256:3811787313eba226a2ef38658c6ccb91cd5e110edc89c37767de373120a0e5a0`
(index digest, verified with `docker buildx imagetools inspect`; 8.10.2 is the
newest 8.10 patch, released 2026-09-17). Flags, `maxmemory` 150mb, `noeviction`,
AOF, the 256 MiB limit and the healthcheck are unchanged. W5b was deferred until
after W8 so the evidence would cover the client versions that now run.

Client compatibility, exercised from this branch against a real 8.10.2 server
(each rehearsal prints the broker version it ran against):

- **Chatwoot 4.18.0-ce** (Sidekiq 7.3.10): `scripts/rehearse-chatwoot-upgrade.sh`
  passes on a copy of production data, including Sidekiq registration, inline
  and queued jobs, and the Agent Bot delivery.
- **Dify 1.17.1** (Celery worker, API cache and locks, plugin daemon):
  `scripts/rehearse-dify-upgrade.sh --invoke` passes, including the migration
  lock, the Celery ping, a document indexed by the worker and one real request
  per app.
- **Evolution 2.3.7**: `scripts/tests/test-evolution.sh` passes with the
  compose-pinned Redis as its cache.
- **Persistence**: `scripts/tests/test-redis.sh` now boots 7.2.16 with the
  compose flags, writes strings, lists, sorted sets, hashes and streams with
  TTLs in DBs 0/1/2, forces a multipart AOF rewrite plus an incremental tail,
  and reopens the same volume with 8.10.x; everything is preserved across the
  upgrade and a second restart.

What changes with 8.x:

- **Licence**: Redis 8 is offered under RSALv2, SSPLv1 or AGPLv3. This stack
  only runs the unmodified image as an internal broker and does not offer Redis
  as a service, so no option restricts it; recorded for the operator.
- **Bundled modules**: the image now loads search, JSON, time series,
  probabilistic and vector set modules. Nothing here uses them. Idle footprint
  rises from about 10 MiB to about 28 MiB of the 256 MiB limit.
- **One-way data files**: an 8.x server can read the 7.2 AOF/RDB, but 7.2 must
  never be started on files written by 8.x. Rollback is the cold backup.

Operator-only apply (use section 3's `dc`; same shape as W5a):

1. Four CI gates and both reviews pass. `dc pull redis`. Record key counts per
   DB.
2. Kill switch on. Stop `autoheal`, then `self-healing-agent`, `middleware`,
   `evolution-api`; then `chatwoot-rails` and `dify-api`. Confirm the Sidekiq
   and Celery queues are quiescent without purging anything; stop
   `chatwoot-sidekiq`, `dify-worker`, `dify-plugin-daemon`.
3. Authenticated `SAVE`, then `dc stop redis`; confirm it exited with code 0.
   Cold-archive the whole `redis-data` volume; verify the archive.
4. `dc up -d --no-deps redis`. Verify the version, authenticated `PING`,
   `NOAUTH` without credentials, `loading:0`, AOF enabled with last write `ok`,
   `maxmemory` 157286400 with `noeviction`, and the key counts.
5. Start `dify-plugin-daemon`, then `dify-worker chatwoot-sidekiq`, then
   `dify-api chatwoot-rails`, then `evolution-api middleware
   self-healing-agent`, then `autoheal`. Kill switch off.
   `scripts/run-stack.sh validate` and `scripts/health-check-all.sh`; confirm
   Sidekiq and Celery process work.
6. **R1:** quiesce again, stop Redis, set the 8.x volume aside, restore the
   cold archive into an empty volume, reinstate the 7.2.16 pin, recreate only
   Redis. Never open 8.x files with 7.2. Never touch the Postgres volume.

### W9 — Node 24 operational contract

Both Dockerfiles use `node:24.21.0-alpine3.24@sha256:ebfe2f90462722a7a4de65e91990e97fe0d401c70e0e762c5b53302f905ec1c1`
(index digest, verified with `docker buildx imagetools inspect`) in every stage:
middleware moves from Node 22, self-healing from Node 20. CI moves to Node 24
in the same change (`stack-compose-playwright`, `unit-tests`,
`validate-tenants`), so CI never tests a runtime that production does not run.
The dead GCP workflows are left alone.

Dependency updates stay inside the current majors (majors are W10):

- middleware and self-healing: axios 1.20, pg 8.23, the OpenTelemetry set
  (sdk-node, OTLP HTTP exporter and http instrumentation 0.222; pg
  instrumentation 0.74; pino instrumentation 0.68; resources and
  sdk-trace-base 2.11; semantic conventions 1.43), `@types/node` 24,
  `@types/pg` 8.23; `engines.node` is now `>=24.0.0` in both.
- middleware only: fastify 5.12.5, `@fastify/sensible` 6.0.6, tsx 4.23.15.
  `@opentelemetry/instrumentation-fastify` stays at 0.57.0, the newest
  published.
- root, provisioning and onboarding (tooling, not deployed): `@types/node` 24
  where present, axios 1.20, pg 8.23, tsx 4.23.15, yaml 2.9.1, and fastify
  5.12.5 in onboarding.
- Unchanged on purpose: vitest (4.x in middleware, 2.x in self-healing),
  Playwright, React, Vite, zod, pino, TypeScript 5.9: all W10.

Checked under the pinned Node 24 image: middleware `typecheck`, `build` and
107 unit tests; self-healing `typecheck`, `build` and 24 unit tests; root
`typecheck`; provisioning `build`; both images build and run as non-root on
v24.21.0. npm 11 (shipped with Node 24) warns on install that protobufjs's
postinstall script is not approved; that script only checks a version and the
OpenTelemetry exporter works without it (telemetry preload exercised under
Node 24). `npm audit --omit=dev` is clean for self-healing. For middleware the
`fast-uri` advisories were fixed in the lockfile (3.1.0 to 3.1.8); the
remaining one is `@fastify/static` 8.x, whose fix is the 10.x major scheduled
for W10b. Its exposure here is low: the plugin only serves the public admin
assets, with no directory listing and no guarded route behind it.

Operator-only apply (use section 3's `dc`, from the main checkout):

1. Four CI gates and both reviews pass. Record the image IDs of
   `nexaduo/middleware:local` and `nexaduo/self-healing-agent:local` and tag
   them `:pre-w9` for R0.
2. Build both images from the merged commit with the tags the production
   `.env` names.
3. `dc up -d --no-deps middleware self-healing-agent`. Middleware is stateless;
   Chatwoot retries a bot webhook that hits the restart.
4. Verify: both healthy on Node v24.21.0, non-root; middleware `/health` and
   `/metrics`; `/config` rejects a request without the shared secret;
   self-healing fetched its config (fail-loud otherwise) and its loop is
   running; traces from both services still reach Tempo; no restart loop.
   `scripts/run-stack.sh validate` and `scripts/health-check-all.sh`.
5. **R0:** retag the `:pre-w9` images back to `:local` and
   `dc up -d --no-deps middleware self-healing-agent`. No data migration is
   involved.

### W10a — Vitest 5 and Playwright 1.63 operational contract

Test tooling only; no production image changes.

- **Vitest 5.0.3** in middleware (from 4.1) and self-healing (from 2.1). The
  107 and 24 unit tests pass unchanged under Node 24. Self-healing gains a
  `vitest.config.mts` limiting collection to `src/**/*.test.ts`: since Vitest 3
  `dist/` is no longer excluded by default, so after a build the compiled
  copies of the tests were collected and failed. In self-healing the old Vitest
  had to be uninstalled first: Vitest 5 needs Vite 6.4 or newer as a peer and
  the lock still carried Vite 5.
- **Playwright 1.63.0** in onboarding (from 1.59.1). It installs Chromium and
  its system dependencies on Ubuntu 26.04 (checked in an `ubuntu:26.04`
  container), which 1.59.1 could not, so `validate-stack` moves from
  `ubuntu-24.04` to `ubuntu-26.04` like the other jobs.
- Both tools require Node 20 or newer (Vitest 5: 22.12+/24); W9 is the
  prerequisite.

Operator apply: nothing is recreated. On the host, `npm ci` in `onboarding/`
and `npx playwright install chromium` so `scripts/run-stack.sh validate` uses
the new version (CI adds `--with-deps` because its runner starts without the
system libraries; the host already has them), then run `validate` and
`scripts/health-check-all.sh`.
Rollback: revert the manifests and locks and reinstall.

### W10b — React 19, Vite 8 and @fastify/static 10 operational contract

Middleware only. The admin SPA (`middleware/admin-ui`, two components) moves to
React 19.3 with `@types/react` 19, Vite 8.3 and `@vitejs/plugin-react` 6.1; the
server moves from `@fastify/static` 8.3 to 10.1.5.

- **Security**: `npm audit --omit=dev` is now clean for middleware. The 8.x
  line of `@fastify/static` carried path-normalisation advisories (route guard
  bypass, directory-listing traversal: GHSA-pr96-94w5-mx2h,
  GHSA-x428-ghpx-8j92, GHSA-8pvw-jcv7-9cmj, GHSA-83w8-p2f5-377r). The plugin here only serves the public
  SPA assets under `/admin/app/assets/`, without listing, so exposure was low;
  the upgrade removes it.
- **Behaviour pinned by a new test** (`src/handlers/admin-static.test.ts`): a
  built asset is served with a JavaScript content type; `..`, encoded `..`,
  backslash, null-byte, double-slash, sibling-prefix, dotfile and directory
  requests are refused (several of them by Fastify's router before the plugin
  is reached; the test pins the outcome, not which layer refuses); the SPA
  entry still redirects to the login without a session. The plugin now sets
  `dotfiles: "deny"`. The plugin was never
  registered in the existing unit tests, because the build output does not
  exist under `src/`.
- No code change was needed in the SPA or the server: `typecheck`, both
  TypeScript builds, the Vite build and the 110 unit tests pass on Node 24.
  The bundle grows from about 149 kB to about 225 kB (48 to 71 kB gzipped).

Operator apply: tag the current middleware image `:pre-w10b`, build from the
merged commit, `dc up -d --no-deps middleware`. Verify `/health`, that
`/admin/login` renders, that the asset referenced by `/admin/app` (after login)
is served with 200, that a traversal attempt under `/admin/app/assets/` is
refused, then `scripts/run-stack.sh validate` and
`scripts/health-check-all.sh`. The React screens themselves need a logged-in
browser check by the operator. **R0:** retag `:pre-w10b` to `:local` and
recreate middleware.
