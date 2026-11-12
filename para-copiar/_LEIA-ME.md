# Pasta pronta para copiar

Esta pasta espelha o layout do repositório de destino. Copie o conteúdo para a raiz dele, numa branch própria criada a partir de `develop`. Os arquivos que começam com `_` e a pasta `_ferramentas/` não são para copiar.

Tudo aqui se faz pelo Git Bash: não é preciso PowerShell, WSL nem Ansible na máquina.

| Arquivo | Vai para | O que é |
|---|---|---|
| `playbooks/restart_glue_job.yml` | `playbooks/` | Playbook de restart do laboratório, com os campos de fechamento do ambiente |
| `playbooks/vars/vars.yml` | `playbooks/vars/` | Tudo o que depende do ambiente: campos do evento, estados aceitos, papel na AWS, regras de elegibilidade e campos de fechamento |
| `plugins/modules/glue_job_run.py` | `plugins/modules/` | Módulo que inicia, para e consulta execuções do Glue |
| `rulebooks/servicenow-glue-aap.yml` | `rulebooks/` | Rulebook da activation: separa os eventos do Glue e entrega o evento ao job template |
| `collections/requirements.yml` | `collections/` | Coleções necessárias (juntar ao que já existir) |

## Como o evento é lido

O rulebook só confere que o evento é do Glue (`jobSource` igual a `aws.glue`) e entrega o evento inteiro ao job template, na variável `evento`. Todo o resto é decidido pelo playbook, a partir do `playbooks/vars/vars.yml`:

| No `vars.yml` | O que define | Valor inicial |
|---|---|---|
| `evento_campos` | Em qual campo do evento vem cada dado: incidente, conta, região, job, execução e estado | `number`, `account`, `region`, `jobName`, `jobRunId`, `jobState` |
| `evento_incidente_tipo` | Se o campo do incidente traz o número ou o `sys_id` | `numero` |
| `glue_estados_travado` | Estados que a automação trata | `TIMEOUT` |
| `aws_papel_automacao`, `aws_external_id` | Papel assumido na conta do job | `AJUSTAR` |
| `aws_regioes_permitidas` | Regiões aceitas; vazio aceita qualquer uma | vazio |
| `job_elegibilidade` | Quais jobs podem ser reiniciados: `tag`, `lista` ou `todos` | `tag` (`auto-remediacao=sim`) |

Se um dado vier em outro campo, basta trocar o nome em `evento_campos` e dar push: não é preciso mexer no rulebook nem na activation.

**Não há catálogo de contas.** A conta e a região vêm do evento, e o playbook assume o papel `aws_papel_automacao` na conta que vier. O que limita onde a automação age passa a ser: o papel existir na conta e confiar na identidade do AAP, a tag (ou lista) do job e, se preenchida, a lista de regiões. Conta sem o papel recebe a nota "não foi possível assumir o papel" e nada é feito.

Evento com estado fora de `glue_estados_travado` termina sem tocar no incidente. Nos demais casos de recusa (dado ausente ou fora do padrão, job sem a tag, execução que não travou), o motivo fica anotado no incidente. O ID da execução pode vir com o sufixo de nova tentativa (`jr_..._attempt_1`).

Como o Event Stream entrega todos os eventos do Glue, cada um vira um job curto no AAP, mesmo os ignorados. Se o volume incomodar, acrescente o estado à condição do rulebook.

### Pontos em aberto

1. **Qual campo liga o evento ao incidente**, e se o incidente já existe quando o evento chega ao EDA. O exemplo de evento recebido não traz esse dado. Quando o nome do campo for conhecido, ele vai em `evento_campos.incidente` (e `evento_incidente_tipo`, se for `sys_id`). Sem ele, o job falha dizendo que o evento não traz o incidente, e nada é feito.
2. **Quais estados entram no restart.** O exemplo recebido é de um job em `FAILED` por erro de instalação de módulo; reiniciar não resolve esse tipo de erro. A pasta sai aceitando só `TIMEOUT`; a lista fica em `glue_estados_travado`.
3. **Fechamento do incidente.** O playbook grava direto os campos do padrão de fechamento do ambiente (abaixo). Se a regra for passar por um role ou playbook comum de fechamento, troque as tarefas "Resolver o incidente" e "Resolver o incidente como duplicado" por essa chamada.
4. **Valor de `u_automation_status` quando a automação não resolve.** Só o valor de sucesso foi informado; nos casos de recusa ou falha o playbook anota o motivo no incidente e não grava esse campo.
5. **Quem envia o evento ao Event Stream** e com qual autenticação.

### Fechamento do incidente

Além de estado, código e notas de resolução, o playbook grava os campos de `sn_campos_ao_assumir` e `sn_campos_ao_resolver` (`playbooks/vars/vars.yml`):

| Momento | Campos |
|---|---|
| Ao assumir (*In Progress*) | `assigned_to` (usuário genérico) e a nota de trabalho |
| Ao resolver | `assigned_to`, `resolved_by`, `u_automation_status` = `SUCESSO`, `u_impact_end` = hora da resolução, com `close_code` = `Solved (Permanently)` |

## Antes de copiar: três conferências no repositório de destino

1. **Onde ficam os módulos.** Abra o `ansible.cfg` e a pasta `plugins/`.
   - Com `library = plugins/modules` (ou caminho parecido) no `ansible.cfg`: copie como está.
   - Se os módulos ficam dentro de uma coleção do repositório: mova o `glue_job_run.py` para a pasta de módulos dela e troque `glue_job_run` pelo nome completo (`<namespace>.<coleção>.glue_job_run`) em todas as tarefas do playbook **e** na chave do `module_defaults`.
   - Se nenhuma das duas valer: mova o módulo para `playbooks/library/glue_job_run.py`. O Ansible carrega essa pasta sozinho, sem configuração.
2. **Onde ficam as variáveis.** Se o padrão for `inventories/<ambiente>/group_vars/`, leve o conteúdo de `vars.yml` para lá e tire o `vars_files` do playbook.
3. **O que a esteira exige.** Veja os workflows em `.github` e os playbooks que já existem (nomes de arquivo, lint). Se o lint exigir nome completo de módulo, vale a segunda opção do item 1.

## Copiar pelo Git Bash

Troque os dois caminhos e o nome da branch. O `cp -rn` não sobrescreve o que já existe no repositório.

```bash
cd /c/caminho/do/repositorio
```

```bash
git checkout develop && git pull && git checkout -b feature/restart-glue-job
```

```bash
cp -rn /c/caminho/para-copiar/playbooks /c/caminho/para-copiar/plugins /c/caminho/para-copiar/rulebooks .
```

```bash
git status --short
```

O `collections/requirements.yml` fica de fora do comando de propósito: junte as duas coleções ao arquivo que já existir. Se o `git status` não mostrar algum dos arquivos da tabela, é porque já havia um com o mesmo nome; compare antes de decidir.

Sem Ansible na máquina, a checagem de sintaxe e o lint ficam por conta da esteira, no push.

## Depois de copiar: o que preencher

Procure por `AJUSTAR` nos arquivos. São estes pontos:

- `playbooks/vars/vars.yml`: o campo do incidente em `evento_campos`, o papel de automação (`aws_papel_automacao`), o usuário genérico em `sn_campos_ao_assumir` e `sn_campos_ao_resolver`, e o código de resolução para duplicado. Os códigos precisam existir na instância.
- `rulebooks/servicenow-glue-aap.yml`: organização e nome do job template.

Enquanto `aws_papel_automacao` estiver com `AJUSTAR`, o playbook recusa qualquer evento e não chama a AWS.

## O que o AAP precisa ter

- Job template apontando para `playbooks/restart_glue_job.yml`, com *Prompt on launch* nas variáveis (o rulebook passa a variável `evento`).
- Credencial da AWS que consiga assumir o papel de automação nas contas dos jobs.
- Credencial que injete as variáveis de ambiente `SN_HOST` (com `https://`), `SN_USERNAME` e `SN_PASSWORD`. Se a credencial do ambiente usar outros nomes, ajuste os três `lookup` no `vars.yml`.
- Execution environment com `amazon.aws` (9 ou superior), `servicenow.itsm` (2.8 ou superior) e `boto3`; decision environment com `ansible.eda`.
- No EDA: Event Stream, credencial do controller e a activation com este rulebook, mapeando a fonte para o Event Stream.

### Criar esses objetos pela tela

O passo a passo pela console web, sem API nem token, está em [`_AAP-pela-tela.md`](_AAP-pela-tela.md).

### Criar esses objetos pelo Git Bash

O `_ferramentas/aap_configurar.sh` cria tudo isso pela API do AAP, só com `curl` e `perl`, que já vêm no Git Bash. Ele precisa de senha local ou de um token de API do AAP; sem nenhum dos dois, use o roteiro da tela.

1. Copie `_ferramentas/aap_configurar.conf.exemplo` para `_ferramentas/aap_configurar.conf` e preencha: URL do AAP, organização, repositório e branch, nomes do execution environment e do decision environment, e os nomes dos objetos no padrão do ambiente. O arquivo não guarda senha.
2. Veja o que seria feito, sem alterar nada:
   ```bash
   bash _ferramentas/aap_configurar.sh --simular
   ```
3. Rode de verdade. As senhas e o token são pedidos na hora, sem aparecer na tela:
   ```bash
   bash _ferramentas/aap_configurar.sh
   ```

Pontos de atenção:

- **Antes de rodar**, a branch precisa estar no Git com o playbook e o rulebook: o AAP sincroniza o repositório e só então cria o job template e a activation.
- **Login por SSO:** sem senha local, crie um token de API no seu usuário do AAP e passe pela variável `AAP_TOKEN` (`read -rs AAP_TOKEN && export AAP_TOKEN`).
- **Credencial da AWS e credenciais do repositório** não são criadas pelo script: ele usa as que já existem, pelo nome.
- **Tipo de credencial da ServiceNow:** criar tipo de credencial exige administrador da plataforma. O tipo que o script cria injeta `SN_HOST` e `SN_INTEGRACAO_SENHA`, e não o usuário: usando o script, escreva o usuário em `sn_integracao_usuario` e troque `SN_PASSWORD` por `SN_INTEGRACAO_SENHA` no `vars.yml`.
- **Usuário do EDA:** `EDA_CONTROLLER_USUARIO` é a conta com que o EDA lança o job template. Ela só precisa do papel *Execute* nele; o script tenta conceder e avisa se não conseguir.
- No fim, o script mostra a URL do Event Stream, que é a que o emissor dos eventos precisa chamar.

Para conferir que o Event Stream recusa token errado (esperado: 403):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Authorization: errado' -H 'Content-Type: application/json' -d '{}' 'URL-DO-EVENT-STREAM'
```

## O que ficou de fora

- Montagem do laboratório (CloudFormation, job de teste, simulação, scripts de configuração do lab).
- Regra do EventBridge e business rule da ServiceNow (`acionar_eda.js`): no laboratório são elas que abrem o incidente e chamam o EDA; aqui o evento já vem do monitoramento de jobs.
- Rulebooks do modo de linha de comando (webhook local e polling).

## Validação feita nesta pasta

Os arquivos desta pasta rodaram no AAP 2.7 do laboratório, neste mesmo layout, numa branch de teste com os valores de lá (papel de automação, usuário e código de resolução do laboratório).

- **Pelo Event Stream e pela activation**, com eventos no formato do monitoramento:
  - evento em `FAILED` terminou em "Evento ignorado", sem tocar no incidente;
  - evento de outra origem não gerou job, e token errado recebeu 403;
  - texto com `{{ }}` nos campos do evento não foi avaliado: o nome de job com chaves foi recusado, com nota no incidente;
  - evento de uma execução já reiniciada fechou o incidente como duplicado;
  - com três restarts na última hora, o quarto foi recusado com a nota do limite.
- **Caminho principal**, com o job template lançado à mão e a variável `evento`: o job assumiu o incidente, reiniciou um job travado de verdade e resolveu o incidente. A credencial temporária não apareceu no log.
- **Pela linha de comando**, onze cenários contra a AWS e a ServiceNow do laboratório: campos do evento com outros nomes, incidente por `sys_id`, elegibilidade por lista e `todos`, conta sem o papel, região fora da lista, job e execução inexistentes, execução que não travou, papel não preenchido, evento sem o incidente e evento em estado não tratado.

Não foi conferido:

- a gravação de `u_automation_status` e `u_impact_end` e o código `Solved (Permanently)`, que não existem na instância de teste;
- as variáveis `SN_USERNAME` e `SN_PASSWORD` injetadas por uma credencial do AAP (no laboratório a credencial injeta outros nomes);
- o roteiro do `_AAP-pela-tela.md` clique a clique: os objetos e campos são os mesmos criados pela API no laboratório, mas a sequência de telas não foi refeita numa console.

O `aap_configurar.sh` foi testado no Git Bash contra um AAP simulado e contra o AAP 2.7 do laboratório (criação de um conjunto completo de objetos, segunda execução e rulebook alterado). Não foram exercitados num AAP de verdade: a autenticação por `AAP_TOKEN`, a concessão do papel *Execute* a um usuário próprio do EDA, o uso de credenciais de repositório e a execução com um usuário que não seja administrador.
