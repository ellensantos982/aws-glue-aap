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

O evento é o incidente que a ServiceNow envia ao Event Stream do AAP. O identificador do incidente (`sys_id`) vem na raiz do evento, e os dados do job vêm num bloco dentro dele (`u_additional_info`).

O rulebook só confere que o incidente é de um job Glue (`u_additional_info.alert_type` igual ao tipo de alerta dos jobs Glue, preenchido na condição do rulebook) e que ele é novo (`state` igual a `1`), e entrega o evento inteiro ao job template, na variável `evento`. Todo o resto é decidido pelo playbook, a partir do arquivo de variáveis, `playbooks/glue-playbooks/vars/restart_glue_job.yml`:

| No arquivo de variáveis | O que define | Valor inicial |
|---|---|---|
| `evento_bloco_do_job` | Em qual bloco do evento ficam os dados do job; vazio = na raiz | `u_additional_info` |
| `evento_campos` | Em qual campo vem cada dado: incidente (na raiz), conta, região, job, execução e estado (no bloco) | `sys_id`, `account_id`, `region`, `jobname`, `jobrunid`, sem campo de estado |
| `evento_execucao_texto_campo`, `evento_execucao_texto_padrao` | Onde procurar o ID da execução quando ele não vem como campo do bloco: um campo de texto da raiz e a expressão regular | `description`, linha `jobrunid: jr_...` |
| `evento_incidente_tipo` | Se o campo do incidente traz o `sys_id` ou o número | `sys_id` |
| `glue_estados_travado` | Estados que a automação trata | `TIMEOUT`, `FAILED`, `ERROR` |
| `aws_papel_automacao`, `aws_external_id` | Papel assumido na conta do job | `AJUSTAR` |
| `aws_regioes_permitidas` | Regiões aceitas; vazio aceita qualquer uma | vazio |
| `job_elegibilidade` | Quais jobs podem ser reiniciados: `tag`, `lista` ou `todos` | `tag` (`auto-remediacao=sim`) |

Se um dado vier em outro campo, basta trocar o nome em `evento_campos` e dar push: não é preciso mexer no rulebook nem na activation. O bloco pode chegar como objeto ou como texto JSON; o playbook lê os dois.

**Não há catálogo de contas.** A conta e a região vêm do evento, e o playbook assume o papel `aws_papel_automacao` na conta que vier. O que limita onde a automação age passa a ser: o papel existir na conta e confiar na identidade do AAP, a tag (ou lista) do job e, se preenchida, a lista de regiões. Conta sem o papel recebe a nota "não foi possível assumir o papel" e nada é feito.

O incidente não traz o estado da execução: o playbook consulta a execução no Glue e só reinicia se ela estiver num dos estados de `glue_estados_travado`. O ID da execução também não vem como campo: ele é lido da descrição do incidente (linha `jobrunid: jr_...`). Nos casos de recusa (dado ausente ou fora do padrão, job sem a tag, execução em outro estado), o motivo fica anotado no incidente. O ID da execução pode vir com o sufixo de nova tentativa (`jr_..._attempt_1`).

Cada incidente novo de job Glue que chegar vira um job no AAP. Uma atualização do mesmo incidente (por exemplo, a que o próprio playbook faz ao assumi-lo) não lança outro job, porque a condição exige `state` igual a `1`.

### Usar um Event Stream que já recebe os eventos

Se os eventos do Glue já chegam a um Event Stream do AAP e outra activation os lê, não é preciso mudar nada em quem envia: um Event Stream pode alimentar várias activations, e cada uma recebe todos os eventos. Basta escolher esse mesmo Event Stream no mapeamento de fontes da activation nova.

Dois cuidados:

- **As duas activations agem sobre o mesmo evento.** Confira o que o outro rulebook faz com o incidente antes de ligar esta automação, para as duas não disputarem o mesmo incidente.
- **Confira o formato antes.** Crie primeiro uma activation com o `rulebooks/glue-eventos-observar.yml`: ela só mostra cada evento no log (aba *History*), sem lançar job nem tocar em nada. Com o evento real na mão, acerte `evento_campos` no arquivo de variáveis e a condição do rulebook principal, e apague a activation de leitura.

### Pontos em aberto

1. **Formato do evento: conferido com um incidente real.** Os dados do job vêm em `u_additional_info` (`alert_type`, `account_id`, `region`, `jobname`), sem campo de estado, e o ID da execução vem só no texto da descrição. Falta conferir se todo alerta de Glue traz a linha `jobrunid:` na descrição; sem ela o playbook recusa o incidente com uma nota.
2. **Quais estados entram no restart.** O alerta recebido é de falha de execução. A pasta sai aceitando `TIMEOUT`, `FAILED` e `ERROR`; a lista fica em `glue_estados_travado`. Falha por erro de código ou de dado se repete no restart: o limite de `max_restarts` segura a repetição e o incidente fica aberto com a nota.
3. **O identificador da ação executada** (`sn_u_action_to_be_taken`). O role de fechamento exige esse valor, que é cadastrado na ServiceNow para cada automação. Sem ele o playbook recusa o evento antes de reiniciar o job.
4. **O nome do papel de automação** (`aws_papel_automacao`): o mesmo papel que os outros playbooks de AWS do repositório assumem, se ele alcançar o Glue.
5. **De onde vêm o endereço e o token da ServiceNow** no job template: uma credencial que injete as variáveis de ambiente, ou as variáveis `instance_url` e `sn_access_token`.
6. **Regra própria ou regra no rulebook existente.** Se o ambiente concentra as regras da ServiceNow num único rulebook, o caminho definitivo pode ser uma regra nele, em vez de uma activation separada. A activation separada funciona em paralelo e serve para o desenvolvimento.

### ServiceNow: autenticação e fechamento

O playbook fala com a ServiceNow pela Table API, com autenticação Basic por token (`usuário:senha` em base64), no mesmo esquema do role de fechamento do repositório. Ele não usa a coleção `servicenow.itsm`.

| Variável | De onde vem |
|---|---|
| `sn_url` | Variável `instance_url`, ou variável de ambiente `SN_HOST` |
| `sn_token_basic` | Variável `sn_access_token`, ou variável de ambiente `SN_ACCESS_TOKEN` |
| `sn_validar_certificado` | `true`; passe para `false` só se o execution environment não confiar no certificado da instância |

O que o playbook grava no incidente:

| Momento | Como |
|---|---|
| Recusa, andamento e falha | Nota de trabalho, direto pela API |
| Ao assumir | Estado *In Progress*, nota de trabalho e, se `sn_usuario_automacao` estiver preenchido, `assigned_to` |
| Ao resolver | Pelo role indicado em `sn_role_de_fechamento` (valor inicial: `servicenow/encerra_incidente`), que recebe o incidente, o endereço, o token, a ação executada, o responsável, o código e as notas de resolução |

Com `sn_role_de_fechamento` vazio, o playbook resolve direto pela API: estado *Resolved*, código, notas e os campos de `sn_campos_ao_resolver` (`u_automation_status` e `u_impact_end`).

## Antes de copiar: o que conferir no repositório

São só leituras, na raiz do repositório.

1. **O execution environment do job template.** O playbook precisa de `amazon.aws` (9 ou superior) e `boto3`. Procure por esses nomes nos arquivos de definição dos execution environments.
2. **O `ansible.cfg`.** Se ele fixar `library`, o módulo pode precisar ir para a pasta indicada ali, em vez de ficar ao lado do playbook. Se `roles_path` não incluir a pasta de roles do repositório, o role de fechamento não é encontrado.
3. **Como os job templates são criados.** Se houver um arquivo de estado desejado por ambiente, aplicado pela esteira, o job template entra por ele, e não pela tela.
4. **O rulebook que já lê os eventos do mesmo Event Stream**, se houver. Os campos que ele usa mostram onde vêm o incidente e os dados.
5. **O role de fechamento de incidente.** Confira o nome, as variáveis que ele exige e os valores padrão; o playbook passa `idIncidente`, `instance_url`, `sn_access_token`, `u_action_to_be_taken`, `assigned_to`, `automation_status`, `u_additional_info`, `close_code`, `close_notes` e `work_notes`.
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

- `playbooks/glue-playbooks/vars/restart_glue_job.yml`: o papel de automação (`aws_papel_automacao`), a ação executada (`sn_u_action_to_be_taken`) e o código de resolução para duplicado. Os códigos precisam existir na instância.
- `rulebooks/servicenow-glue-aap.yml`: organização e nome do job template.

Enquanto `aws_papel_automacao` ou `sn_u_action_to_be_taken` estiverem com `AJUSTAR`, o playbook recusa qualquer evento, anota o motivo no incidente e não chama a AWS.

## O que o AAP precisa ter

- Job template apontando para `playbooks/glue-playbooks/restart_glue_job.yml`, com *Prompt on launch* nas variáveis (o rulebook passa a variável `evento`).
- Identidade na AWS que consiga assumir o papel de automação nas contas dos jobs: uma credencial *Amazon Web Services* no job template, ou o perfil das máquinas do instance group.
- Endereço e token da ServiceNow: uma credencial que injete `SN_HOST` (com `https://`) e `SN_ACCESS_TOKEN`, ou as variáveis `instance_url` e `sn_access_token`.
- Execution environment com `amazon.aws` (9 ou superior) e `boto3`; decision environment com `ansible.eda`.
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
- **Credencial da ServiceNow:** o tipo que o script cria injeta `SN_HOST` e a senha em `SN_INTEGRACAO_SENHA`, e não o token Basic que o playbook espera. Usando o script, monte o token em `sn_token_basic`, no arquivo de variáveis, a partir do usuário e dessa senha. Criar tipo de credencial exige administrador da plataforma.
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

Os arquivos desta pasta rodaram no AAP 2.7 do laboratório, neste desenho, numa branch de teste com os valores de lá (papel de automação, usuário e instância de teste) e com um role de fechamento escrito com as mesmas entradas, validações e chamada do role do repositório de destino.

- **Pelo Event Stream e pela activation**, com eventos no formato do incidente (`sys_id` na raiz e dados do job em `u_additional_info`):
  - estado não tratado: evento ignorado, sem tocar no incidente;
  - incidente de outra origem: nenhum job lançado;
  - nome de job com `{{ }}`: não foi avaliado e foi recusado, com nota no incidente;
  - execução que não travou: recusada, com nota no incidente;
  - execução já reiniciada: incidente fechado como duplicado **pelo role de fechamento**, com o responsável padrão do role.
- **Fechamento direto pela API** (`sn_role_de_fechamento` vazio), com o job template lançado à mão: incidente fechado como duplicado, com `assigned_to` e `resolved_by`.
- **Sem depender de ambiente:** sintaxe, leitura do bloco como objeto e como texto JSON, e o rulebook carregado no `ansible-rulebook`.

Não foi conferido nesta versão:

- **O restart completo** (assumir o incidente, reiniciar e resolver). As etapas de AWS são as mesmas da versão anterior, que reiniciou um job travado de verdade no mesmo AAP; o que mudou foi a forma de gravar no incidente.
- **O role de fechamento verdadeiro**: o teste usou um equivalente, escrito a partir da leitura dele.
- **Bloco como texto JSON pelo Event Stream:** nesse formato a condição do rulebook não enxerga `alert_type` e a regra não dispara. O playbook lê os dois formatos, mas o rulebook espera o bloco como objeto.
- Os campos `u_automation_status` e `u_impact_end` e o código `Solved (Permanently)`, que não existem na instância de teste.

A versão anterior do playbook (ServiceNow pela coleção `servicenow.itsm`, campos do evento na raiz) também passou por: limite de restarts, conta sem o papel, região fora da lista, job inexistente, elegibilidade por lista e duas activations no mesmo Event Stream.

O `aap_configurar.sh` foi testado no Git Bash contra um AAP simulado e contra o AAP 2.7 do laboratório.
