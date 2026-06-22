# NexaDuo Workspace Agent Rules & Guidelines

This file defines the project-scoped guidelines and rules that all agents working on this workspace must follow.

## Core Directives

### 1. Testes de Regressão no Playwright (Obrigatoriedade para Bugs)
Sempre que um bug for corrigido, o agente deve obrigatoriamente avaliar se faz sentido adicionar um teste de regressão ou asserção no Playwright para evitar que o erro ocorra novamente.

- **Quando faz sentido:**
  - Bugs de autenticação (ex: sessões expiradas, cookie security, redirecionamentos de login).
  - Problemas de roteamento (ex: redirecionamentos infinitos com SSL, links quebrados na interface).
  - Falhas em APIs consumidas pela UI (ex: erros 401, 500 no refresh de token ou rotas do console).
  - Validações de campos de formulário e fluxos de usuário ponta-a-ponta (E2E) que podem ser simulados via navegador.
- **Quando não faz sentido:**
  - Bugs de infraestrutura interna ou lógica que não são expostos/detectados no fluxo de usuário da web, tais como otimização de consultas SQL internas que não afetam respostas HTTP de maneira observável.
  - Configurações internas do sistema operacional.
  - Lógica interna do banco de dados que já é coberta por testes unitários.
  - Scripts auxiliares rodados sob demanda via CLI.
  *Se o agente decidir que não faz sentido criar um teste no Playwright, ele deve justificar essa decisão na descrição da alteração ou em sua mensagem final.*
- **Como implementar:**
  - Crie ou edite arquivos dentro do diretório `onboarding/tests/` (ex: crie um novo arquivo `onboarding/tests/XX-nome-do-bug.spec.ts` ou adicione asserções no arquivo relevante como `03-smoke.spec.ts` ou `05-console-network.spec.ts`).
  - Capture falhas de rede usando interceptores de resposta do Playwright (`page.on('response', ...)` ou `page.waitForResponse(...)`).
  - Adicione comentários no código do teste explicando qual bug a asserção está prevenindo.
- **Validação:**
  - Antes de concluir a correção de um bug, o agente deve obrigatoriamente rodar os testes localmente (`npm run test:all` dentro da pasta `onboarding`) e garantir que a nova asserção/teste de regressão passe, além de monitorar o workflow no CI.

### 2. Diretrizes de Release, Deploy e Acompanhamento de Workflows
- **Fases Obrigatórias no Plano:** Todo plano de implementação deve obrigatoriamente conter etapas claras para:
  1. Deploy em Staging.
  2. Validação E2E/Fumaça em Staging.
  3. Deploy em Produção.
  4. Validação E2E/Fumaça em Produção.
- **Monitoramento Ativo de Workflows:** O agente não deve considerar a tarefa concluída apenas ao abrir o PR ou fazer o push. Ele deve monitorar a execução dos workflows do GitHub Actions (via logs, comandos `gh run watch` ou checagens no Git) até que o deploy em staging e produção seja concluído com sucesso.
- **Validação com URLs Reais:** A validação final em staging e produção deve ser feita executando os testes automatizados (como os testes do Playwright) apontando para as URLs de produção/staging correspondentes, e nunca apenas localmente.
