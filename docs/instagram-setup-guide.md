# Conectando um Instagram (canal nativo do Chatwoot)

> **Importante:** o Instagram é conectado pelo **canal nativo do Chatwoot**
> (Meta App + Instagram Login / OAuth), **não** pela Evolution API. A Evolution é
> **WhatsApp-only** e não suporta Instagram em nenhuma versão (issue #31). O antigo
> `scripts/provision-instagram.sh` e o fluxo "Conectar Instagram Direct" do admin
> portal foram removidos por isso.

## Pré-requisitos (lado Meta — uma vez por plataforma)

1. Conta Instagram **Business/Creator** vinculada a uma Página do Facebook.
2. App no [developers.facebook.com](https://developers.facebook.com) com o produto
   **Instagram → API setup with Instagram login**.
3. Envs do Chatwoot já provisionados (via terraform `tenant`): `INSTAGRAM_APP_ID`,
   `INSTAGRAM_APP_SECRET`, `INSTAGRAM_VERIFY_TOKEN`. O deploy reconcilia esses
   valores nos `installation_configs` e valida o handshake do webhook
   (ver lição "Chatwoot installation_configs mask env").
4. No painel da Meta, em **Business login settings**, adicione a **OAuth redirect
   URI** exatamente: `https://<FRONTEND_URL>/instagram/callback`
   (ex.: `https://chat.nexaduo.com/instagram/callback`). O Chatwoot monta esse
   `redirect_uri` a partir de `FRONTEND_URL` (`base_url` em `instagram_concern.rb`).
   Scopes: `instagram_business_basic`, `instagram_business_manage_messages`.
5. Webhook do App apontando para `https://<FRONTEND_URL>/webhooks/instagram` com o
   mesmo `INSTAGRAM_VERIFY_TOKEN`, inscrito no campo `messages`.

> Em modo *Development* do App, só contas adicionadas como **test users/roles**
> conseguem mandar DM. Para produção, é preciso **App Review** da Meta.

## Conectar a conta (por tenant)

1. Logue no Chatwoot do tenant (ex.: `https://chat.nexaduo.com`) **na conta certa**
   (cada tenant é um *account* separado).
2. **Settings → Inboxes → Add Inbox → Instagram** → login OAuth com a conta
   profissional do Instagram.
3. O Chatwoot cria o `Channel::Instagram` + Inbox e assina o webhook
   automaticamente. DMs novos passam a chegar como conversas.

## Habilitar a IA (Dify) para o inbox

O middleware roteia por `chatwoot_account_id` → app do Dify via tabela `tenants`.
Para a conta responder via IA:

- **Reproduzível (canônico):** adicione o tenant em `tenants.yaml`
  (`infra.dify_app_type` + `infra.dify_api_key: "gcp-secret:<nome>"`) e rode o
  deploy/seed.
- **Runtime (rápido):** use a tela **Configuração de Dify** do admin portal
  (`/admin/app`) para setar `dify_app_type` + a API key da conta. ⚠️ Isso grava só
  no banco; para reprodutibilidade, replique em `tenants.yaml` + Secret Manager.

## Verificar

- Mande um DM novo de outro perfil → a conversa aparece no inbox do tenant.
- Logs do middleware devem mostrar `account_id=<id> status=ok` (não
  `no_tenant_mapping`) e a resposta da IA cai na conversa.
