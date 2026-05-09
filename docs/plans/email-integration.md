# Plano de Integração: Envio de Emails via Resend

Este documento descreve o plano para configurar o envio de e-mails transacionais (redescobrimento de senha, notificações, convites) para os serviços da stack NexaDuo utilizando o provedor **Resend**.

## 1. Gestão de Segredos

O token do Resend já foi salvo no Google Cloud Secret Manager e mapeado para sincronização local.

- **Nome no GCP:** `resend_api_key`
- **Variável de Ambiente:** `RESEND_API_KEY`
- **Script de Sincronização:** Atualizado em `scripts/sync-secrets-gcp.sh`.

Para atualizar o ambiente local:
```bash
./scripts/sync-secrets-gcp.sh
```

## 2. Configuração do Chatwoot

O Chatwoot utiliza o ActionMailer do Ruby on Rails. A configuração será feita via variáveis de ambiente nos serviços `chatwoot-rails` e `chatwoot-sidekiq`.

### Variáveis a Adicionar:
| Variável | Valor Sugerido | Observação |
| :--- | :--- | :--- |
| `SMTP_ADDRESS` | `smtp.resend.com` | Host do Resend |
| `SMTP_PORT` | `587` | Porta para TLS |
| `SMTP_AUTHENTICATION` | `plain` | Método de auth |
| `SMTP_DOMAIN` | `nexaduo.com` | Domínio verificado no Resend |
| `SMTP_ENABLE_STARTTLS_AUTO` | `true` | Habilitar TLS automático |
| `SMTP_USERNAME` | `resend` | Usuário padrão do Resend |
| `SMTP_PASSWORD` | `${RESEND_API_KEY}` | Token da API |
| `MAILER_SENDER_EMAIL` | `NexaDuo <accounts@nexaduo.com>` | Remetente verificado |

### Local: `deploy/docker-compose.chatwoot.yml`

---

## 3. Configuração do Dify

O Dify utiliza configurações de e-mail para recuperação de senha e convites de membros da equipe.

### Variáveis a Adicionar:
| Variável | Valor Sugerido | Observação |
| :--- | :--- | :--- |
| `MAIL_TYPE` | `smtp` | Tipo de driver |
| `MAIL_HOST` | `smtp.resend.com` | Host do Resend |
| `MAIL_PORT` | `587` | Porta para TLS |
| `MAIL_USERNAME` | `resend` | Usuário padrão do Resend |
| `MAIL_PASSWORD` | `${RESEND_API_KEY}` | Token da API |
| `MAIL_USE_TLS` | `true` | Usar TLS |
| `MAIL_DEFAULT_SEND_FROM` | `accounts@nexaduo.com` | E-mail do remetente |
| `MAIL_DEFAULT_SEND_FROM_NAME` | `NexaDuo` | Nome do remetente |

### Local: `deploy/docker-compose.dify.yml` (serviço `dify-api`)

---

## 4. Configuração do Grafana

O Grafana permite o envio de alertas e convites via e-mail.

### Variáveis a Adicionar:
| Variável | Valor Sugerido | Observação |
| :--- | :--- | :--- |
| `GF_SMTP_ENABLED` | `true` | Habilitar SMTP |
| `GF_SMTP_HOST` | `smtp.resend.com:587` | Host e porta |
| `GF_SMTP_USER` | `resend` | Usuário |
| `GF_SMTP_PASSWORD` | `${RESEND_API_KEY}` | Token da API |
| `GF_SMTP_FROM_ADDRESS` | `accounts@nexaduo.com` | Remetente |
| `GF_SMTP_FROM_NAME` | `NexaDuo Grafana` | Nome exibido |
| `GF_SMTP_STARTTLS_POLICY` | `MandatoryStartTLS` | Segurança |

### Local: `deploy/docker-compose.nexaduo.yml` (serviço `grafana`)

---

## 5. Próximos Passos

1. [ ] **Verificação de Domínio:** Garantir que `nexaduo.com` está verificado no painel do Resend.
2. [ ] **Atualização dos Compose:** Inserir as variáveis nos arquivos YAML de deploy.
3. [ ] **Deploy:** Reiniciar os serviços para aplicar as novas configurações.
4. [ ] **Teste de Fumaça:** Solicitar recuperação de senha em ambos os sistemas.
