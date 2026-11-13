# Pasta pronta para copiar

Esta pasta segue o desenho do repositório de destino: playbooks em subpastas por assunto, rulebooks na raiz de `rulebooks/` e plugins próprios ao lado do playbook que os usa. Copie o conteúdo para a raiz do repositório, numa branch própria criada a partir de `develop`. Os arquivos que começam com `_` e a pasta `_ferramentas/` não são para copiar.

Tudo aqui se faz pelo Git Bash: não é preciso PowerShell, WSL nem Ansible na máquina.

| Arquivo | O que é |
|---|---|
| `playbooks/glue-playbooks/restart_glue_job.yml` | Playbook de restart |
| `playbooks/glue-playbooks/vars/restart_glue_job.yml` | Tudo o que depende do ambiente: campos do evento, estados aceitos, papel na AWS, regras de elegibilidade e campos de fechamento |
| `playbooks/glue-playbooks/library/glue_job_run.py` | Módulo que inicia, para e consulta execuções do Glue |
| `rulebooks/servicenow-glue-aap.yml` | Rulebook da activation: separa os eventos do Glue e entrega o evento ao job template |
| `rulebooks/glue-eventos-observar.yml` | Rulebook só de leitura: mostra os eventos no log da activation, sem lançar job |

Por que cada coisa está onde está:

- **Playbook em `playbooks/glue-playbooks/`:** é a subpasta que já guarda os playbooks do Glue. Nada do que existe lá é alterado.
- **Módulo em `library/`, ao lado do playbook:** o Ansible carrega essa pasta sozinho, sem mexer no `ansible.cfg`. É o mesmo arranjo dos plugins que o repositório já mantém ao lado de playbooks (`filter_plugins/`, `callback_plugins/`). A outra opção é a coleção interna do repositório, mas ela só chega ao AAP depois de publicada e de entrar no execution environment.
- **Sem `collections/requirements.yml`:** o repositório não tem esse arquivo, e criá-lo faria o AAP tentar instalar coleções a cada sincronização do projeto. As coleções precisam vir do execution environment (veja abaixo).

## Como o evento é lido

O rulebook só confere que o evento é do Glue (`jobSource` igual a `aws.glue`) e entrega o evento inteiro ao job template, na variável `evento`. Todo o resto é decidido pelo playbook, a partir do arquivo de variáveis, `playbooks/glue-playbooks/vars/restart_glue_job.yml`:

| No arquivo de variáveis | O que define | Valor inicial |
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

### Usar um Event Stream que já recebe os eventos

Se os eventos do Glue já chegam a um Event Stream do AAP e outra activation os lê, não é preciso mudar nada em quem envia: um Event Stream pode alimentar várias activations, e cada uma recebe todos os eventos. Basta escolher esse mesmo Event Stream no mapeamento de fontes da activation nova.

Dois cuidados:

- **As duas activations agem sobre o mesmo evento.** Confira o que o outro rulebook faz com o incidente antes de ligar esta automação, para as duas não disputarem o mesmo incidente.
- **Confira o formato antes.** Crie primeiro uma activation com o `rulebooks/glue-eventos-observar.yml`: ela só mostra cada evento no log (aba *History*), sem lançar job nem tocar em nada. Com o evento real na mão, acerte `evento_campos` no arquivo de variáveis e a condição do rulebook principal, e apague a activation de leitura.

### Pontos em aberto

1. **Qual campo liga o evento ao incidente**, e se o incidente já existe quando o evento chega ao EDA. O exemplo de evento recebido não traz esse dado. Quando o nome do campo for conhecido, ele vai em `evento_campos.incidente` (e `evento_incidente_tipo`, se for `sys_id`). Sem ele, o job falha dizendo que o evento não traz o incidente, e nada é feito.
2. **Quais estados entram no restart.** O exemplo recebido é de um job em `FAILED` por erro de instalação de módulo; reiniciar não resolve esse tipo de erro. A pasta sai aceitando só `TIMEOUT`; a lista fica em `glue_estados_travado`.
3. **Fechamento do incidente.** O playbook grava direto os campos do padrão de fechamento do ambiente (abaixo). Se a regra for passar por um role ou playbook comum de fechamento, troque as tarefas "Resolver o incidente" e "Resolver o incidente como duplicado" por essa chamada.
4. **Valor de `u_automation_status` quando a automação não resolve.** Só o valor de sucesso foi informado; nos casos de recusa ou falha o playbook anota o motivo no incidente e não grava esse campo.
5. **Quem envia o evento ao Event Stream** e com qual autenticação.

### Fechamento do incidente

Além de estado, código e notas de resolução, o playbook grava os campos de `sn_campos_ao_assumir` e `sn_campos_ao_resolver` (no arquivo de variáveis):

| Momento | Campos |
|---|---|
| Ao assumir (*In Progress*) | `assigned_to` (usuário genérico) e a nota de trabalho |
| Ao resolver | `assigned_to`, `resolved_by`, `u_automation_status` = `SUCESSO`, `u_impact_end` = hora da resolução, com `close_code` = `Solved (Permanently)` |

## Antes de copiar: o que conferir no repositório

São só leituras, na raiz do repositório.

1. **Qual execution environment tem as coleções.** O playbook precisa de `amazon.aws` (9 ou superior), `servicenow.itsm` (2.8 ou superior) e `boto3` no mesmo execution environment. Procure por esses nomes nos arquivos de definição dos execution environments. Se nenhum tiver as duas coleções, peça a inclusão num deles antes de testar.
2. **O `ansible.cfg`.** Se ele fixar `library`, o módulo pode precisar ir para a pasta indicada ali, em vez de ficar ao lado do playbook.
3. **Como os job templates são criados.** Se houver um arquivo de estado desejado por ambiente, aplicado pela esteira, o job template entra por ele, e não pela tela.
4. **O rulebook que já lê os eventos do mesmo Event Stream**, se houver. Os campos que ele usa mostram onde vem o número do incidente.
5. **O role de fechamento de incidente**, se houver. Se a regra for fechar por ele, as duas tarefas de resolução do playbook passam a chamá-lo.
6. **O que a esteira exige.** Veja os workflows e o nome dos playbooks vizinhos (hífen ou sublinhado, extensão `.yml` ou `.yaml`). Se o lint exigir nome completo de módulo, o módulo precisa ir para a coleção interna.

## Copiar pelo Git Bash

Troque os dois caminhos e o nome da branch. O `cp -rn` não sobrescreve o que já existe no repositório.

```bash
cd /c/caminho/do/repositorio
```

```bash
git checkout develop && git pull && git checkout -b feature/restart-glue-job
```

```bash
cp -rn /c/caminho/para-copiar/playbooks /c/caminho/para-copiar/rulebooks .
```

```bash
git status --short
```

O esperado no `git status` são cinco arquivos novos: três em `playbooks/glue-playbooks/` e dois em `rulebooks/`. Se faltar algum, é porque já havia um com o mesmo nome; compare antes de decidir.

Sem Ansible na máquina, a checagem de sintaxe e o lint ficam por conta da esteira, no push.

## Depois de copiar: o que preencher

Procure por `AJUSTAR` nos arquivos. São estes pontos:

- `playbooks/glue-playbooks/vars/restart_glue_job.yml`: o campo do incidente em `evento_campos`, o papel de automação (`aws_papel_automacao`), o usuário genérico em `sn_campos_ao_assumir` e `sn_campos_ao_resolver`, e o código de resolução para duplicado. Os códigos precisam existir na instância.
- `rulebooks/servicenow-glue-aap.yml`: organização e nome do job template.

Enquanto `aws_papel_automacao` estiver com `AJUSTAR`, o playbook recusa qualquer evento e não chama a AWS.

## O que o AAP precisa ter

- Job template apontando para `playbooks/glue-playbooks/restart_glue_job.yml`, com *Prompt on launch* nas variáveis (o rulebook passa a variável `evento`).
- Credencial da AWS que consiga assumir o papel de automação nas contas dos jobs.
- Credencial que injete as variáveis de ambiente `SN_HOST` (com `https://`), `SN_USERNAME` e `SN_PASSWORD`. Se a credencial do ambiente usar outros nomes, ajuste os três `lookup` no arquivo de variáveis.
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
- **Tipo de credencial da ServiceNow:** criar tipo de credencial exige administrador da plataforma. O tipo que o script cria injeta `SN_HOST` e `SN_INTEGRACAO_SENHA`, e não o usuário: usando o script, escreva o usuário em `sn_integracao_usuario` e troque `SN_PASSWORD` por `SN_INTEGRACAO_SENHA` no arquivo de variáveis.
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
- **Duas activations no mesmo Event Stream:** uma activation com o `glue-eventos-observar.yml` foi ligada ao Event Stream que outra activation já lia. Um único evento disparou as duas: a primeira lançou o job dela e a de leitura mostrou o evento inteiro no log, sem a credencial do controller. O cabeçalho de autenticação não aparece no log.
- **Pela linha de comando**, onze cenários contra a AWS e a ServiceNow do laboratório: campos do evento com outros nomes, incidente por `sys_id`, elegibilidade por lista e `todos`, conta sem o papel, região fora da lista, job e execução inexistentes, execução que não travou, papel não preenchido, evento sem o incidente e evento em estado não tratado.

Não foi conferido:

- a gravação de `u_automation_status` e `u_impact_end` e o código `Solved (Permanently)`, que não existem na instância de teste;
- as variáveis `SN_USERNAME` e `SN_PASSWORD` injetadas por uma credencial do AAP (no laboratório a credencial injeta outros nomes);
- o roteiro do `_AAP-pela-tela.md` clique a clique: os objetos e campos são os mesmos criados pela API no laboratório, mas a sequência de telas não foi refeita numa console.

O `aap_configurar.sh` foi testado no Git Bash contra um AAP simulado e contra o AAP 2.7 do laboratório (criação de um conjunto completo de objetos, segunda execução e rulebook alterado). Não foram exercitados num AAP de verdade: a autenticação por `AAP_TOKEN`, a concessão do papel *Execute* a um usuário próprio do EDA, o uso de credenciais de repositório e a execução com um usuário que não seja administrador.
