# Roteiro — screencast do Meta App Review (Instagram)

Roteiro para gravar o vídeo exigido pelo App Review da Meta ao publicar o app
`Maria Eduarda - IG` (Instagram App ID `1042111571516215`).

**Permissões demonstradas:** `instagram_business_basic` e
`instagram_business_manage_messages` (as duas de `docs/instagram-setup-guide.md`).
Se a submissão pedir outras, o vídeo precisa demonstrar **cada uma** — o revisor
rejeita a submissão inteira se sobrar uma permissão sem demonstração.

---

## Regra que faz a maioria das submissões ser rejeitada

O revisor da Meta não avalia se o produto é bom. Ele responde uma única pergunta,
para cada permissão, de forma independente:

> "Eu **vi**, nesta gravação, um usuário real usando a interface deste app de um
> jeito que **só é possível** com esta permissão?"

Disso decorre tudo o mais:

- **Nada de slides, diagramas ou narração sobre arquitetura.** Só a tela do produto
  em uso. Um vídeo que explica a stack é rejeitado por não demonstrar a permissão.
- **Nada de Postman, `curl`, Graph API Explorer ou terminal.** A demonstração tem que
  ser pela interface que o usuário final usa — no nosso caso, o Chatwoot.
- **Sem cortes que escondam passos.** Corte só tempo morto (carregamento). Se o vídeo
  pula do "clicar em conectar" direto para "conectado", o revisor assume que o passo
  não funciona.
- **Inglês.** Narração em inglês ou legendas em inglês na tela. Sem áudio é aceitável
  se houver legendas; narrado é melhor.
- **Duração:** 3 a 6 minutos. Mais que isso o revisor não assiste até o fim.
- **Uma tela só, resolução cheia, cursor visível.** Nada de webcam sobreposta.

---

## Pré-voo — fazer ANTES de apertar o rec

Esta seção é o que separa uma gravação de 20 minutos de uma tarde perdida. Cada item
aqui já quebrou uma tentativa de gravação neste projeto.

### 1. Conversation Routing (senão o envio falha na câmera)

O bug `100 / subcode 2534037` ("não é a dona do tópico") faz **toda** mensagem de saída
falhar enquanto a entrada continua funcionando. Se ele estiver ativo, você vai gravar a
mensagem sendo escrita e depois aparecendo como **failed** — pior que não gravar.

Verifique na Página do Facebook vinculada à conta Instagram:
Page Settings → Page setup → **Advanced messaging** → **Default routing app** →
tem que estar o app que dono do canal (`Maria Eduarda - IG`).

Detalhe do runbook (`AGENTS.md`): a conta `miau.duda` **tem** Página vinculada
("Maria Eduarda"), mesmo tendo sido assumido por meses que não tinha. Não repita a
suposição — abra e confirme.

### 2. Janela de 24h aberta

A Meta valida a janela de mensagens **antes** da posse do tópico. Numa thread parada, o
envio falha com `code=10 / subcode=2534022` (fora da janela), que **mascara** qualquer
outro problema. Peça para a conta de teste mandar uma DM nova para a conta de negócios
**no mesmo dia da gravação**, de preferência minutos antes.

### 3. Ensaio completo, sem gravar

Rode o fluxo inteiro uma vez do início ao fim. Confirme que a resposta do bot chega e
que a mensagem fica com status **sent** (não `failed`). Só depois grave.

### 4. Higiene de tela — o que NÃO pode aparecer

- Nenhum terminal, nenhum `.env`, nenhum token, nenhuma senha.
- Nada de `GET /me/conversations` na tela: a resposta traz `paging.next` com o
  `access_token` embutido na URL.
- **Chatwoot com dados de outros tenants.** Este é um stack multi-tenant; a caixa de
  entrada e a lista de contatos podem expor conversas reais de terceiros. Use uma conta
  Chatwoot limpa, só com a inbox do Instagram de teste, e confira a barra lateral antes
  de gravar. Vazar conversa de cliente para um revisor externo é um incidente de
  privacidade, não um detalhe estético.
- Feche notificações do sistema, abas pessoais e qualquer coisa com nome de cliente.

### 5. Contas

- **Conta de negócios:** a conta Instagram Business que o app gerencia.
- **Conta de teste (o "cliente"):** outra conta, num celular, para mandar a DM. Grave a
  tela do celular em paralelo ou mostre o celular filmado — o revisor precisa ver a
  mensagem sendo enviada pelo lado do usuário. Alternativa aceita: gravar o Instagram
  web numa segunda janela.

---

## Roteiro — 6 cenas

Os textos em inglês abaixo são para você ler em voz alta (ou virar legenda). Estão
propositalmente curtos e literais: o revisor precisa ouvir o nome da permissão e ver o
que ela habilita, na mesma frase.

### Cena 1 — Abertura e identificação (0:00 – 0:20)

**Tela:** tela de login do Chatwoot em `https://chat.nexaduo.com`.

> "This is a customer support application that lets a business manage its Instagram
> direct messages from a single shared inbox, with an AI assistant drafting replies.
> I'm going to demonstrate the two permissions we're requesting:
> `instagram_business_basic` and `instagram_business_manage_messages`."

**Cuidado:** faça o login de verdade na câmera. Não comece já logado — o revisor
gosta de ver a sessão sendo criada.

### Cena 2 — Conectar a conta Instagram: consentimento (0:20 – 1:30)

Esta é a cena mais importante do vídeo. É a única prova de que o app pede as permissões
pelo caminho oficial.

**Tela:** dentro do Chatwoot → Settings → Inboxes → **Add Inbox** → Instagram.

1. Clique em conectar. Mostre o redirecionamento para o Instagram.
2. **Pare na tela de consentimento e deixe-a visível por 3 a 4 segundos parada.** É aqui
   que aparecem as permissões sendo pedidas. Se essa tela passar rápido demais, o
   revisor não consegue ler e rejeita.
3. Autorize. Mostre o retorno para o Chatwoot com a inbox criada.

> "The business owner authorizes our app through Instagram's official login flow. On
> this consent screen you can see the app requesting access to the account's basic
> profile information and to its messages."

### Cena 3 — `instagram_business_basic` (1:30 – 2:10)

**Tela:** a inbox recém-criada no Chatwoot, mostrando o nome de usuário, o nome de
exibição e a foto de perfil da conta Instagram conectada.

> "`instagram_business_basic` is what lets the application identify the connected
> account. Here you can see the Instagram username, display name and profile picture
> pulled from the account — without this permission the business could not tell which
> Instagram account this inbox belongs to."

Passe o mouse devagar por cima de cada elemento enquanto narra. O revisor precisa
associar cada dado na tela à permissão que o produziu.

### Cena 4 — Mensagem recebida (2:10 – 3:00)

**Tela:** dividida ou alternada entre o celular (conta de teste) e o Chatwoot.

1. No celular, mostre a conta de teste abrindo o Instagram e mandando uma DM para a
   conta de negócios. Algo natural, como uma pergunta de cliente: *"Hi, are you open on
   Sundays?"*
2. Volte para o Chatwoot e mostre a mensagem **chegando** na inbox, com o nome e a foto
   do remetente.

> "A customer sends a direct message to the business on Instagram. Thanks to
> `instagram_business_manage_messages`, the message is delivered to our application and
> appears in the shared inbox, where the support team can see it."

### Cena 5 — Resposta enviada (3:00 – 4:00)

Esta cena prova a metade de **escrita** da permissão, que é a que a Meta mais
escrutina.

1. No Chatwoot, mostre a resposta do assistente (ou digite uma resposta manualmente —
   as duas servem; digitar é mais claro para o revisor).
2. Envie.
3. **Mostre a mensagem com status de enviada no Chatwoot.**
4. **Volte para o celular e mostre a mensagem chegando na conversa do Instagram.** Esta
   volta ao celular é obrigatória: é a única prova de que a mensagem realmente saiu, e
   não apenas foi aceita pela interface.

> "The agent replies from the shared inbox. `instagram_business_manage_messages` is what
> allows the application to send that reply back through Instagram — and here it is,
> arriving in the customer's Instagram conversation."

### Cena 6 — Encerramento (4:00 – 4:30)

**Tela:** a conversa completa no Chatwoot, com ida e volta.

> "That's the full flow: the business connects its Instagram account, receives customer
> messages in a shared inbox, and replies to them. Both permissions are used only for
> this customer support use case."

---

## Checklist final antes de submeter

- [ ] O vídeo mostra a tela de consentimento parada e legível.
- [ ] Cada permissão pedida na submissão aparece demonstrada e **nomeada** em voz/legenda.
- [ ] A mensagem enviada aparece **chegando no celular do cliente**, não só saindo.
- [ ] Nenhum terminal, token, `.env` ou conversa de outro tenant apareceu.
- [ ] Áudio em inglês ou legendas em inglês do início ao fim.
- [ ] Nenhum corte esconde um passo do fluxo.
- [ ] Menos de 6 minutos.
- [ ] Enviado em MP4, 1080p.

## Se for rejeitado

A Meta manda o motivo em texto, quase sempre genérico. Antes de regravar, releia a
seção "Superseded" do `AGENTS.md`: neste projeto já se queimou Advanced Access, Live
mode, Instagram Tester e re-OAuth atrás de uma causa raiz **errada**. Se a rejeição
mencionar algo que você não consegue reproduzir na tela, confirme a causa antes de
mudar a configuração do app.
