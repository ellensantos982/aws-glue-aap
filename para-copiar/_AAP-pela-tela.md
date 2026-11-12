# Configurar o AAP pela tela

Roteiro para criar os objetos do AAP pela console web, sem API e sem token. Os nomes de menu são os do AAP 2.5 em diante (console unificada, em inglês); em outra versão a posição pode mudar um pouco, mas os campos são os mesmos.

Antes de começar:

- A branch com `playbooks/`, `plugins/` e `rulebooks/` já está no Git, com o `vars.yml` e o rulebook preenchidos.
- Tenha em mãos: a organização, o nome do execution environment e do decision environment, e a credencial do repositório (se ele for privado).
- Escolha o nome do job template agora: ele precisa ser **idêntico** ao que está no rulebook (`name:`), assim como a organização.

Os objetos marcados com *(se não existir)* costumam já existir no ambiente. Nesse caso, use o que existe.

## Parte 1: Automation Execution

### 1. Credencial da ServiceNow

O playbook lê três variáveis de ambiente: `SN_HOST` (com `https://`), `SN_USERNAME` e `SN_PASSWORD`.

- **Se o ambiente já tem uma credencial da ServiceNow:** use essa. Abra o tipo dela em *Automation Execution → Infrastructure → Credential Types* e veja quais variáveis ela injeta. Se os nomes forem outros, troque os três `lookup` de `sn_host`, `sn_integracao_usuario` e `sn_integracao_senha` no `vars.yml`.
- **Se não tem:** crie o tipo e a credencial. Criar tipo de credencial exige administrador da plataforma; se o botão não aparecer, peça a criação com os dois blocos abaixo.

*Automation Execution → Infrastructure → Credential Types → Create credential type*

Input configuration:

```yaml
fields:
  - id: sn_host
    type: string
    label: Instancia (https://...)
  - id: sn_usuario
    type: string
    label: Usuario de integracao
  - id: sn_senha
    type: string
    label: Senha
    secret: true
required:
  - sn_host
  - sn_usuario
  - sn_senha
```

Injector configuration:

```yaml
env:
  SN_HOST: '{{ sn_host }}'
  SN_USERNAME: '{{ sn_usuario }}'
  SN_PASSWORD: '{{ sn_senha }}'
```

Depois, *Automation Execution → Infrastructure → Credentials → Create credential*: nome, organização, o tipo acima e os três valores.

### 2. Credencial da AWS *(se não existir)*

Tipo *Amazon Web Services*. Ela só precisa conseguir assumir o papel de `aws_papel_automacao` nas contas dos jobs. Normalmente já existe uma no ambiente; anote o nome.

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

Salve e espere o status *Successful*. Com essa opção, toda alteração no `vars.yml` vale no job seguinte, sem sincronizar à mão.

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
| Playbook | `playbooks/restart_glue_job.yml` |
| Execution environment | um com `amazon.aws`, `servicenow.itsm` e `boto3` |
| Credentials | a da AWS **e** a da ServiceNow |
| Extra variables | marque **Prompt on launch** |

O *Prompt on launch* das variáveis é obrigatório: sem ele o AAP descarta a variável `evento` que o EDA envia, e o playbook para dizendo que o evento não traz o incidente.

### 6. Teste do job template

Lance o job template à mão (*Launch template*) com estas variáveis:

```yaml
evento:
  jobSource: aws.glue
  jobState: FAILED
```

O job deve terminar com sucesso em segundos, com a mensagem "Evento ignorado: estado FAILED". Isso prova que projeto, execution environment e variáveis estão certos, sem tocar na AWS nem na ServiceNow.

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

A activation guarda uma cópia do rulebook. Se o rulebook mudar no Git (organização, nome do job template, condição), sincronize o projeto do EDA e crie a activation de novo. Mudança no `vars.yml` não exige nada disso.

## Parte 3: conferir

1. **Activation:** em *Rulebook Activations*, abra a activation; a aba *History* mostra o log.
2. **Evento de teste:** peça um evento de teste ao emissor, ou envie um pelo Git Bash se tiver o token do Event Stream:
   ```bash
   curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Authorization: Bearer TOKEN' -H 'Content-Type: application/json' -d '{"jobSource": "aws.glue", "jobState": "FAILED"}' 'URL-DO-EVENT-STREAM'
   ```
   O esperado é `200`, e em seguida um job novo em *Automation Execution → Jobs*, terminando com "Evento ignorado". Com token errado, o esperado é `403`.
3. **Regra disparada:** *Automation Decisions → Rule Audit* lista cada disparo e o job lançado.

## Se algo não funcionar

| Sintoma | Causa provável |
|---|---|
| O evento chega (200) e nenhum job aparece | O evento não tem `jobSource` igual a `aws.glue`, ou a organização ou o nome do job template no rulebook não batem com o AAP (veja o log da activation) |
| Job falha com "O campo ... não traz um número de incidente válido" | Falta o *Prompt on launch* das variáveis no job template, ou o campo do incidente tem outro nome (`evento_campos.incidente` no `vars.yml`) |
| Job termina em "Evento ignorado" | O estado do evento não está em `glue_estados_travado` |
| Nota no incidente: "não foi possível assumir o papel" | O papel não existe na conta do job, ou não confia na identidade da credencial da AWS |
| Job falha ao falar com a ServiceNow | Credencial da ServiceNow fora do job template, ou injetando variáveis com outros nomes |
| Módulo `glue_job_run` não encontrado | Veja "Onde ficam os módulos" no `_LEIA-ME.md` |
