> Plano gerado pelo Codex (planejamento read-only) em 2026-09-27, revisado pelo `@techlead`. Épico: #219. Versões/links refletem a consulta dessa data — revalidar por onda.

# Plano de atualização — Multitenant Chat Services

Data da consulta: **27/09/2026**. Planejamento somente; nenhum Docker, teste, deploy, commit ou push foi executado. AGENTS.md foi lido primeiro. O host único é produção; CI efêmera não é staging. Caminhos abaixo são relativos à raiz do repositório.

**Decisão:** atualizar em PRs sequenciais, preservar contratos e dados, substituir Promtail por Alloy e deixar PostgreSQL major para uma janela própria, opcional. “Última estável” não equivale a “troca segura de tag”. **ASSUMED** identifica informação não comprovada ou condição que impede liberar a onda.

## 1. Inventário reproduzível

Legenda: **T** = tag de versão explícita, ainda mutável; **F** = flutuante (latest, major/minor ou intervalo); **V** = variável, valor efetivo não inspecionado; **D** = digest/hash. Nenhuma imagem literal dos Compose/Dockerfiles está fixada por digest. Não li `.env`, estados Terraform nem segredos. Pins do código não provam versões em execução.

### Imagens e runtimes

| Arquivo:linha | Referência atual | Tipo |
|---|---|---|
| `deploy/docker-compose.chatwoot.yml:34,72,126` | `chatwoot/chatwoot:v4.13.0-ce` | T |
| `deploy/docker-compose.dify.yml:32` | `alpine:3.19` | F |
| `deploy/docker-compose.dify.yml:43,124` | `langgenius/dify-api:1.13.3` | T |
| `deploy/docker-compose.dify.yml:180` | `langgenius/dify-web:1.13.3` | T |
| `deploy/docker-compose.dify.yml:217` | `langgenius/dify-sandbox:0.2.14` | T |
| `deploy/docker-compose.dify.yml:236` | `langgenius/dify-plugin-daemon:0.5.3-local` | T |
| `deploy/docker-compose.dify.yml:268` | `ubuntu/squid:latest` | F |
| `deploy/docker-compose.localproxy.yml:61` | `traefik:v3.6.25` | T |
| `deploy/docker-compose.nexaduo.yml:16` | `evoapicloud/evolution-api:v2.1.1` | T |
| `deploy/docker-compose.nexaduo.yml:54` | `${MIDDLEWARE_IMAGE}` | V |
| `deploy/docker-compose.nexaduo.yml:94` | `grafana/loki:3.2.0` | T |
| `deploy/docker-compose.nexaduo.yml:126` | `grafana/promtail:3.1.0` | T |
| `deploy/docker-compose.nexaduo.yml:161` | `grafana/grafana:11.6.16` | T |
| `deploy/docker-compose.nexaduo.yml:205` | `prom/prometheus:v2.55.0` | T |
| `deploy/docker-compose.nexaduo.yml:232` | `${SELF_HEALING_IMAGE}` | V |
| `deploy/docker-compose.nexaduo.yml:257` | `otel/opentelemetry-collector-contrib:0.111.0` | T |
| `deploy/docker-compose.nexaduo.yml:283` | `grafana/tempo:2.6.1` | T |
| `deploy/docker-compose.shared.yml:55` | `pgvector/pgvector:pg16` | F |
| `deploy/docker-compose.shared.yml:90` | `redis:7.2.4-alpine` | T |
| `deploy/docker-compose.shared.yml:151` | `cloudflare/cloudflared:latest` | F |
| `deploy/docker-compose.shared.yml:201` | `willfarrell/autoheal:1.2.0` | T |
| `middleware/Dockerfile:8,15,24,31` | `node:22-alpine` | F |
| `agents/self-healing/Dockerfile:1,9` | `node:20-alpine` | F |
| `scripts/backup-host.sh:56` | `BACKUP_HELPER_IMAGE=alpine:3.20` | F (minor) |
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

Tempo `observability/tempo/tempo.yaml:3` repete o pin `2.6.1` em comentário. Collector, Prometheus e provisioning usam configurações sem pin adicional de software. Azure `gpt-4o`/`gpt-4o-mini` são deployments externos: versão real, API version e disponibilidade **ASSUMED**, não são imagens a atualizar via Compose.

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
| Dify ssrf-proxy | [Squid 7.7](https://www.squid-cache.org/Versions/) | **Alto/condicional**: nenhuma imagem `ubuntu/squid` stable 7.7 verificada; não inventar tag nem adotar beta como estável. W7a propõe build versionado de Squid 7.7; digest/build **ASSUMED** |
| Dify init / helper backup | [Alpine 3.24.2](https://alpinelinux.org/releases/) → `alpine:3.24.2` | **Baixo**: tar/chown, UID 1001 e permissões; imagens auxiliares também precisam digest |
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
- **Tempo:** [migração](https://grafana.com/docs/tempo/latest/set-up-for-tracing/setup-tempo/upgrade/) exige vParquet4+, remove blocos `ingester`/`compactor` presentes no YAML local e não oferece downgrade 3→2. Fazer ponte 2.10.8, verificar blocos em disco e migrar config monolítica. [Collector changelog](https://github.com/open-telemetry/opentelemetry-collector-contrib/blob/v0.161.0/CHANGELOG.md): normalização de nomes/sufixos Prometheus e mudanças health_check requerem comparação; não usamos os exporters removidos Loki/Jaeger.
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
| **W5b — Redis8.10.2-alpine, condicional** | S, documentação de clientes/licença | Só após provar compatibilidade dos clientes atuais; novo backup frio; `dc up -d --no-deps redis`; mesmas verificações, sem aumentar memória implicitamente | R1 dados7.2.16+pin, nunca abrir AOF8 com7; **CI muda**, se falhar adiar até após Chatwoot |
| **W6 — Evolution2.3.7** | N, `.env.production.example`, fixtures/testes webhook | Backup DB evolution + volume/sessões Redis; suspender autoheal durante migrations; `dc up -d --no-deps evolution-api`; esperar Prisma e reconectar instância; texto/áudio/documento inbound/outbound pelo Chatwoot, sem contatos duplicados | R1 evolution/instances/chaves Redis da instância +2.1.1; **CI muda**, migrations/fixtures, Meta validado live |
| **W7a — Squid7.7 + Alpine3.24.2** | D, futura receita `deploy/squid/Dockerfile` + config/entrypoint, backup-host.sh, exemplos | **Bloqueada para release até imagem reproduzível verificada.** Build Squid7.7 com checksums, ACL e proxy envs; `dc up -d --no-deps dify-ssrf-proxy`; helper Alpine via backup de teste; init chown em fixture, não reexecutar recursivamente live sem necessidade | R0 imagem/config anterior capturada; **CI muda** ACL, HTTP tool e sandbox |
| **W7b — Dify1.17.1 + sandbox0.2.15 + plugin0.6.10-local** | D, root/isolated/CI override se serviços mudarem, `.env.production.example`, dify-apps, clients/testes middleware/admin | Backup `dify`, `dify_plugin`, api-storage+plugin-storage; sequência detalhada abaixo; checks RAG/Azure/SSE/handoff/config; init Alpine já fixado em W7a | R1 dois DBs+volumes+pins1.13.3/0.2.14/0.5.3-local; **CI muda**, upgrade fixture e readiness |
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
- **ASSUMED — Squid:** catálogo/README divergiram sobre destino de latest (README7.2-beta, API aponta digest também associado6.6-beta). Não escolher versão a partir desse alias. Release7.7 é comprovada, mas build/container/entrypoint/ACL ainda precisam implementação e teste; W7a fica bloqueada até então. Não declarar a atual proteção SSRF funcional só pela existência do container.
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
