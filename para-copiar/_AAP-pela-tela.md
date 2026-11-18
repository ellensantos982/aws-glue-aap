# Configurar o AAP pela tela

Roteiro para criar os objetos do AAP pela console web, sem API e sem token. Os nomes de menu são os do AAP 2.5 em diante (console unificada, em inglês); em outra versão a posição pode mudar um pouco, mas os campos são os mesmos.

Antes de começar:

- A branch com `playbooks/glue-playbooks/` e `rulebooks/` já está no Git, com o arquivo de variáveis (`playbooks/glue-playbooks/vars/restart_glue_job.yml`) e o rulebook preenchidos.
- Tenha em mãos: a organização, o nome do execution environment e do decision environment, e a credencial do repositório (se ele for privado).
- Escolha o nome do job template agora: ele precisa ser **idêntico** ao que está no rulebook (`name:`), assim como a organização.

Os objetos marcados com *(se não existir)* costumam já existir no ambiente. Nesse caso, use o que existe.

Se os job templates do ambiente são criados por código (um arquivo de estado desejado aplicado pela esteira), o job template do passo 5 entra por lá, e não pela tela. Os campos são os mesmos da tabela do passo 5.

## Parte 1: Automation Execution

### 1. Endereço e token da ServiceNow

O playbook precisa do endereço da instância e de um token de autenticação Basic (`usuário:senha` em base64). Ele lê os dois das variáveis `instance_url` e `sn_access_token` ou, na falta delas, das variáveis de ambiente `SN_HOST` e `SN_ACCESS_TOKEN`.

- **Se o ambiente já tem uma credencial que injeta o token** (a que os playbooks de ServiceNow do repositório usam): use essa no job template. Abra o tipo dela em *Automation Execution → Infrastructure → Credential Types* e confira os nomes das variáveis; se forem outros, troque `sn_url` e `sn_token_basic` no arquivo de variáveis.
- **Se não tem:** crie o tipo e a credencial. Criar tipo de credencial exige administrador da plataforma; se o botão não aparecer, peça a criação com os dois blocos abaixo.

Input configuration:

```yaml
fields:
  - id: sn_host
    type: string
    label: Instancia (https://...)
  - id: sn_token
    type: string
    label: Token Basic (usuario:senha em base64)
    secret: true
required:
  - sn_host
  - sn_token
```

Injector configuration:

```yaml
env:
  SN_HOST: '{{ sn_host }}'
  SN_ACCESS_TOKEN: '{{ sn_token }}'
```

### 2. Identidade na AWS

O playbook assume o papel de `aws_papel_automacao` na conta do job. Para isso o job precisa de uma identidade na AWS: uma credencial do tipo *Amazon Web Services* no job template, ou o perfil das máquinas do instance group em que o job roda. Veja como os outros job templates de AWS do ambiente fazem e repita.

### 3. Projeto

*Automation Execution → Projects → Create project*

| Campo | Valor |
|---|---|
| Name / Organization | no padrão do ambiente |
| Source control type | Git |
| Source control URL | URL do repositório |
| Source control branch/tag/commit | a branch |
| Source control credential | a do repositório, se for privado |
| Options | marque **Update revision on launch** |

Salve e espere o status *Successful*. Com essa opção, toda alteração no arquivo de variáveis vale no job seguinte, sem sincronizar à mão.

### 4. Inventário *(se não existir um com `localhost`)*

*Automation Execution → Infrastructure → Inventories → Create inventory*: só nome e organização. Dentro dele, aba *Hosts → Create host*, com nome `localhost` e estas variáveis:

```yaml
ansible_connection: local
ansible_python_interpreter: '{{ ansible_playbook_python }}'
```

### 5. Job template

*Automation Execution → Templates → Create template → Create job template*

| Campo | Valor |
|---|---|
| Name | o mesmo nome escrito no rulebook |
| Job type | Run |
| Inventory | o do passo 4 |
| Project | o do passo 3 |
| Playbook | `playbooks/glue-playbooks/restart_glue_job.yml` |
| Execution environment | um com `amazon.aws` e `boto3` |
| Credentials | a da ServiceNow (passo 1) e, se for o caso, a da AWS (passo 2) |
| Instance groups | o mesmo dos outros job templates de AWS, se o ambiente usar |
| Extra variables | marque **Prompt on launch** |

O *Prompt on launch* das variáveis é obrigatório: sem ele o AAP descarta a variável `evento` que o EDA envia, e o playbook para dizendo que o evento não traz o incidente.

### 6. Teste do job template

Lance o job template à mão (*Launch template*) com estas variáveis:

```yaml
evento:
  u_additional_info:
    alert_type: AJUSTAR-tipo-do-alerta
```

O job deve parar em segundos na tarefa "Conferir a referência do incidente", com a mensagem "O campo "sys_id" do evento não traz um sys_id válido: nada foi feito". É uma falha esperada: ela prova que projeto, execution environment e variáveis estão certos, sem tocar na AWS nem na ServiceNow.

## Parte 2: Automation Decisions

### 7. Credencial do EDA para lançar o job template *(se não existir)*

*Automation Decisions → Infrastructure → Credentials → Create credential*, tipo *Red Hat Ansible Automation Platform*: a URL é `https://<endereço do AAP>/api/controller/` e a autenticação é usuário e senha ou token de uma conta com permissão de *Execute* no job template.

Sem senha local e sem poder criar token, não dá para criar esta credencial: use a que as outras activations da organização já usam, ou peça uma a quem administra o AAP.

### 8. Event Stream *(se não existir)*

Se os eventos já chegam a um Event Stream do AAP, use esse e pule este passo, mesmo que outra activation já o leia: um Event Stream pode alimentar várias activations. Para escolhê-lo no passo 10, seu usuário precisa enxergar esse Event Stream (ele pertence a uma organização).

1. *Automation Decisions → Infrastructure → Credentials → Create credential*, com um tipo de Event Stream. Para um token simples: tipo *Token Event Stream*, o token combinado com quem envia e o cabeçalho (`Authorization`).
2. *Automation Decisions → Event Streams → Create event stream*: nome, organização, o tipo e a credencial acima. Deixe ligado o encaminhamento dos eventos para a activation (*Forward events to rulebook activation*).
3. Depois de salvar, a tela mostra a URL do Event Stream. É ela que o emissor dos eventos precisa chamar.

### 9. Projeto do EDA

*Automation Decisions → Projects → Create project*: nome, organização, *Source control type* Git, a URL, a branch e a credencial do repositório. Espere o status *Completed*.

### 10. Rulebook activation

*Automation Decisions → Rulebook Activations → Create rulebook activation*

| Campo | Valor |
|---|---|
| Name / Organization | no padrão do ambiente |
| Project | o do passo 9 |
| Rulebook | `servicenow-glue-aap.yml` |
| Event streams | abra o mapeamento e ligue a fonte do rulebook (`ansible.eda.webhook`) ao Event Stream do passo 8 |
| Credential | a do passo 7 |
| Decision environment | um com `ansible.eda` |
| Restart policy | On failure |
| Rulebook activation enabled | ligado |

Salve e espere o status *Running*.

Para só ver os eventos antes de ligar a automação, crie do mesmo jeito uma activation com o rulebook `glue-eventos-observar.yml` (sem a credencial do passo 7, que ela não usa). Cada evento aparece inteiro na aba *History*; depois de conferir, apague essa activation.

A activation guarda uma cópia do rulebook. Se o rulebook mudar no Git (organização, nome do job template, condição), sincronize o projeto do EDA e crie a activation de novo. Mudança no arquivo de variáveis não exige nada disso.

## Parte 3: conferir

1. **Activation:** em *Rulebook Activations*, abra a activation; a aba *History* mostra o log.
2. **Evento de teste:** peça um evento de teste ao emissor, ou envie um pelo Git Bash se tiver o token do Event Stream:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Authorization: Bearer TOKEN' -H 'Content-Type: application/json' -d '{"state": "1", "u_additional_info": {"alert_type": "AJUSTAR-tipo-do-alerta"}}' 'URL-DO-EVENT-STREAM'
   ```
   Use em `alert_type` o mesmo valor da condição do rulebook. O esperado é `200`, e em seguida um job novo em *Automation Execution → Jobs*, parando em "Conferir a referência do incidente" (o evento de teste não traz incidente). Com token errado, o esperado é `403`.
3. **Regra disparada:** *Automation Decisions → Rule Audit* lista cada disparo e o job lançado.

## Se algo não funcionar

| Sintoma | Causa provável |
|---|---|
| O evento chega (200) e nenhum job aparece | O evento não tem `u_additional_info.alert_type` igual ao valor da condição do rulebook e `state` igual a `1`, ou a organização ou o nome do job template no rulebook não batem com o AAP (veja o log da activation) |
| Job falha com "O campo ... não traz um sys_id válido" | Falta o *Prompt on launch* das variáveis no job template, ou o campo do incidente tem outro nome (`evento_campos.incidente` no arquivo de variáveis) |
| Nota no incidente: "a execução ... está em ..., e não em ..." | O estado da execução no Glue não está em `glue_estados_travado` |
| Nota no incidente: "o evento não traz um ID de execução válido" | A descrição do incidente não tem a linha `jobrunid: jr_...` (ajuste `evento_execucao_texto_padrao`) |
| Nota no incidente: "não foi possível assumir o papel" | O papel não existe na conta do job, ou não confia na identidade da credencial da AWS |
| Job falha em "Conferir o endereço e o token da ServiceNow" | A credencial não está no job template, ou injeta variáveis com outros nomes |
| Job falha em "Conferir se o incidente foi localizado" | A mensagem traz o código HTTP: 200 com 0 resultado é incidente inexistente; 401 é token sem acesso; sem resposta costuma ser certificado não confiável (`sn_validar_certificado`) |
| Nota no incidente: "a ação executada ... não está preenchida" | Falta `sn_u_action_to_be_taken` no arquivo de variáveis |
| Módulo `glue_job_run` não encontrado | A pasta `library/` não foi junto com o playbook: ela precisa ficar ao lado dele, em `playbooks/glue-playbooks/library/` |
