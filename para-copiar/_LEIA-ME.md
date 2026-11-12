# Pasta pronta para copiar

Esta pasta espelha o layout do repositório de destino. Copie o conteúdo para a raiz dele, numa branch própria criada a partir de `develop`. Este arquivo (`_LEIA-ME.md`) e a pasta `_ferramentas/` não são para copiar.

Tudo aqui se faz pelo Git Bash: não é preciso PowerShell, WSL nem Ansible na máquina.

| Arquivo | Vai para | O que é |
|---|---|---|
| `playbooks/restart_glue_job.yml` | `playbooks/` | Playbook de restart do laboratório, com os campos de fechamento do ambiente |
| `playbooks/vars/vars.yml` | `playbooks/vars/` | Variáveis do playbook: limites, estados aceitos e campos de fechamento do incidente |
| `playbooks/vars/contas.yml` | `playbooks/vars/` | Catálogo de contas, com uma conta-modelo |
| `plugins/modules/glue_job_run.py` | `plugins/modules/` | Módulo que inicia, para e consulta execuções do Glue |
| `rulebooks/servicenow-glue-aap.yml` | `rulebooks/` | Rulebook da activation: lê o evento do monitoramento de jobs e lança o job template |
| `collections/requirements.yml` | `collections/` | Coleções necessárias (juntar ao que já existir) |

## Formato do evento

O rulebook espera o evento do monitoramento de jobs como um JSON plano, e usa só estes campos:

| Campo do evento | Uso |
|---|---|
| `jobSource` | Precisa ser `aws.glue` |
| `jobState` | Precisa ser `TIMEOUT` (ajustável; veja abaixo) |
| `account`, `region`, `jobName`, `jobRunId` | Viram o `correlation_id` que o playbook recebe: `conta\|região\|job\|execução` |
| `number` | Número do incidente. **O exemplo de evento recebido não traz esse campo**: é o ponto em aberto mais importante |

Os outros campos do evento (descrição, e-mail, grupo e os demais) são ignorados e não chegam ao playbook. Evento com `{`, `}` ou `|` em algum dos campos usados é descartado.

O ID da execução pode vir com o sufixo de nova tentativa (`jr_..._attempt_1`); ele é repassado como está.

### Pontos em aberto

1. **Qual campo liga o evento ao incidente** (número ou `sys_id`), e se o incidente já existe quando o evento chega ao EDA. Enquanto o evento não trouxer o número, a regra não dispara. Se o campo tiver outro nome, troque `number` nas duas linhas marcadas do rulebook.
2. **Quais estados entram no restart.** O exemplo recebido é de um job em `FAILED` por erro de instalação de módulo; reiniciar não resolve esse tipo de erro. A pasta sai aceitando só `TIMEOUT`. Para aceitar outros, mude a condição do rulebook e `glue_estados_travado` em `vars.yml`, sempre os dois.
3. **Fechamento do incidente.** O playbook grava direto os campos do padrão de fechamento do ambiente (abaixo). Se a regra for passar por um role ou playbook comum de fechamento, troque as tarefas "Resolver o incidente" e "Resolver o incidente como duplicado" por essa chamada.
4. **Valor de `u_automation_status` quando a automação não resolve.** Só o valor de sucesso foi informado; nos casos de recusa ou falha o playbook anota o motivo no incidente e não grava esse campo.
5. **Como o evento chega ao EDA** e com qual autenticação. O `_ferramentas/aap_configurar.sh` cria o Event Stream com token no cabeçalho `Authorization`; se o emissor usar outro esquema, crie o Event Stream pela tela.

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
2. **Onde ficam as variáveis.** Se o padrão for `inventories/<ambiente>/group_vars/`, leve o conteúdo de `vars.yml` e `contas.yml` para lá e tire o `vars_files` do playbook.
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

- `playbooks/vars/contas.yml`: ID da conta de dev (a chave `"111122223333"` é só um modelo), nome, papel de automação, ExternalId (se houver), regiões e critério de elegibilidade.
- `playbooks/vars/vars.yml`: `sn_integracao_usuario`, o usuário genérico em `sn_campos_ao_assumir` e `sn_campos_ao_resolver`, e o código de resolução para duplicado. Os códigos precisam existir na instância.
- `rulebooks/servicenow-glue-aap.yml`: organização e nome do job template, o campo do número do incidente e os estados aceitos.

Enquanto o catálogo estiver com a conta-modelo, o playbook recusa qualquer incidente ("a conta não está no catálogo") e não chama o Glue.

## O que o AAP precisa ter

- Job template apontando para `playbooks/restart_glue_job.yml`, com *Prompt on launch* nas variáveis (o rulebook passa `incidente_numero` e `correlation_id`).
- Credencial da AWS que consiga assumir o papel de automação de cada conta do catálogo.
- Credencial que injete as variáveis de ambiente `SN_HOST` (com `https://`) e `SN_INTEGRACAO_SENHA`.
- Execution environment com `amazon.aws` (9 ou superior), `servicenow.itsm` (2.8 ou superior) e `boto3`; decision environment com `ansible.eda`.
- No EDA: Event Stream com token, credencial do controller e a activation com este rulebook, mapeando a fonte para o Event Stream.

### Criar esses objetos pelo Git Bash

O `_ferramentas/aap_configurar.sh` cria tudo isso pela API do AAP, só com `curl` e `perl`, que já vêm no Git Bash. Use quando a configuração não for feita pela esteira nem pela tela.

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
- **Tipo de credencial da ServiceNow:** criar tipo de credencial exige administrador da plataforma. Se o script parar nesse passo, peça a criação do tipo (campos `sn_host` e `sn_senha`, injetando `SN_HOST` e `SN_INTEGRACAO_SENHA`) e rode de novo.
- **Usuário do EDA:** `EDA_CONTROLLER_USUARIO` é a conta com que o EDA lança o job template. Ela só precisa do papel *Execute* nele; o script tenta conceder e avisa se não conseguir.
- No fim, o script mostra a URL do Event Stream, que vai na propriedade da ServiceNow.

Para conferir que o Event Stream recusa token errado (esperado: 403):

```bash
curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Authorization: errado' -H 'Content-Type: application/json' -d '{}' 'URL-DO-EVENT-STREAM'
```

## O que ficou de fora

- Montagem do laboratório (CloudFormation, job de teste, simulação, scripts de configuração do lab).
- Regra do EventBridge e business rule da ServiceNow (`acionar_eda.js`): no laboratório são elas que abrem o incidente e chamam o EDA; aqui o evento já vem do monitoramento de jobs.
- Rulebooks do modo de linha de comando (webhook local e polling).

## Validação feita nesta pasta

Checagem de sintaxe do playbook com o módulo em `plugins/modules/` e leitura dos arquivos YAML. Os arquivos desta pasta, neste layout, não foram executados contra AWS, ServiceNow ou AAP.

A versão do laboratório deste conteúdo rodou no AAP 2.7 de lá: restart de ponta a ponta (incidente resolvido), recusas (formato do `correlation_id`, conta, região, job e execução), evento repetido e descarte de eventos com chaves ou fora do padrão. O módulo só difere dela em comentários e exemplos. O playbook difere nos campos de fechamento, e o rulebook, no formato do evento; essas duas diferenças foram testadas assim:

- **Rulebook:** carregado no `ansible-rulebook`, com eventos fictícios no formato do monitoramento. Só disparou com `aws.glue`, `TIMEOUT`, número de incidente e campos sem `{`, `}` ou `|`, e montou o `correlation_id` certo, inclusive com `_attempt_1`. O exemplo recebido (`FAILED`, sem número) foi descartado. A variante com lista de estados também foi testada.
- **Playbook com os campos de fechamento:** o playbook desta pasta, com os valores do laboratório e pela linha de comando, tratou um job travado de verdade (assumiu o incidente, reiniciou o job e resolveu o incidente) e fechou outro incidente no caminho de execução já reiniciada. `assigned_to` e `resolved_by` foram gravados a partir do nome de usuário. A instância de teste não tem `u_automation_status` nem `u_impact_end`, então a gravação desses dois não foi conferida.
- **Não testado:** o rulebook dentro de uma activation ligada a um Event Stream, e o código `Solved (Permanently)`, que não existe na instância de teste.

O `aap_configurar.sh` foi testado no Git Bash:

- contra um AAP simulado: criação, segunda execução, rulebook alterado, senha errada;
- contra o AAP 2.7 do laboratório, de verdade: atualização dos objetos que já existiam e criação de um conjunto completo com outros nomes (a activation subiu e o Event Stream novo recusou token errado com 403), removido em seguida.

Ainda não foram exercitados num AAP de verdade: a autenticação por `AAP_TOKEN`, a concessão do papel *Execute* a um usuário próprio do EDA, o uso de credenciais de repositório e a execução com um usuário que não seja administrador.
