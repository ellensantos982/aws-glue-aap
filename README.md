# POC: job Glue travado → incidente na ServiceNow → EDA reinicia o job

```
 [AWS Glue] job trava e é encerrado por timeout (estado TIMEOUT)
     │  evento "Glue Job State Change"
     ▼
 [EventBridge] regra + API destination ──► [ServiceNow] abre o incidente pela Table API
                                                │  business rule (async, após inserir)
                                                ▼
                                 [Event-Driven Ansible] webhook com token Bearer
                                                │  rulebook → restart_glue_job.yml
                                                ▼
                     [Ansible] confere conta/região/job no catálogo → assume o papel na conta do job
                               → confere que a execução do incidente travou → assume o incidente
                               → reinicia o job → aguarda → resolve o incidente com as notas de resolução
```

Primeiro com **ansible-core + ansible-rulebook** (CLI, no WSL). Depois o mesmo conteúdo vai para o AAP do lab (seção no fim).

## Pré-requisitos (contas e acessos)

1. **ServiceNow (grátis):** em <https://developer.servicenow.com>, crie a conta de desenvolvedor e peça uma instância (*Request Instance*, versão mais recente). Anote a URL (`https://devNNNNNN.service-now.com`) e a senha do `admin`. A instância hiberna quando fica sem uso: entre no portal para acordá-la antes da demo.
2. **AWS (centavos):** no console, em IAM, crie um usuário `poc-ansible` com *access key* para CLI. Para o POC, `AdministratorAccess` resolve; a lista mínima está no fim. No WSL, grave a chave em `~/.aws/credentials`:
   ```ini
   [poc]
   aws_access_key_id = ...
   aws_secret_access_key = ...
   ```
3. **cloudflared (grátis, sem conta):** cria uma URL pública temporária para a ServiceNow alcançar o EDA na sua máquina.
   ```bash
   mkdir -p ~/.local/bin && curl -L -o ~/.local/bin/cloudflared https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64 && chmod +x ~/.local/bin/cloudflared
   ```

## Subir o POC (no WSL, dentro desta pasta)

```bash
cd poc-glue-servicenow
bash poc.sh preparar        # cria .env (com token do webhook), venv e coleções
```

Preencha no `.env`: `SN_HOST` e uma senha nova em `SN_INTEGRACAO_SENHA` (12+ caracteres); se quiser receber o alarme de eventos não entregues, também `ALERTAS_EMAIL`. A senha do admin da ServiceNow não precisa ficar no `.env`: o comando `servicenow` pede na hora. Depois:

```bash
bash poc.sh servicenow      # usuário de integração, propriedades e business rule na ServiceNow
bash poc.sh aws             # stack CloudFormation: S3, IAM, job Glue, EventBridge -> ServiceNow
```

Em dois terminais separados:

```bash
bash poc.sh eda             # terminal 1: ansible-rulebook escutando na porta 5000
bash poc.sh tunel           # terminal 2: mostra uma URL https://xxxx.trycloudflare.com
```

Aponte a ServiceNow para essa URL (ela muda a cada vez que o túnel sobe):

```bash
bash poc.sh url https://xxxx.trycloudflare.com
```

Teste rápido sem AWS: `bash poc.sh testar-eda INC0010001` manda um incidente fictício direto para o EDA. O playbook roda e falha ao procurar esse incidente, o que já prova que o webhook está funcionando.

## Roteiro da demo

```bash
bash poc.sh simular
```

| Tempo | O que acontece | Onde mostrar |
|---|---|---|
| 0 min | O job inicia e trava (falha injetada uma única vez) | Console do Glue: execução em *Running* |
| ~2 min | O Glue encerra por timeout; o EventBridge abre o incidente | ServiceNow: novo incidente "[AWS Glue] Job travado: poc-glue-sn-carga-diaria", aberto por `poc.integracao.aws` |
| segundos depois | A business rule chama o EDA | Work note: "Event-Driven Ansible acionado (HTTP 200)" |
| | O Ansible confere a execução travada, assume o incidente e reinicia o job | Incidente em *In Progress*; work notes "Ansible recebeu..." e "Job reiniciado: nova execução jr_..."; terminal 1 mostra o playbook |
| ~2 a 3 min | O job reiniciado termina com sucesso | Incidente *Resolved*, com código de resolução e notas do Ansible; Glue com a nova execução *Succeeded* |

## Custo

| Item | Custo por demo |
|---|---|
| Glue: execução travada (2 workers × 2 min) + restart (~1 min) | ~US$ 0,05 |
| EventBridge (regra + API destination) | desprezível (US$ 0,20 por milhão de chamadas) |
| S3, SQS (fila de falhas), CloudFormation | centavos ou grátis |
| ServiceNow PDI e túnel do cloudflared | grátis |

Para remover a parte AWS: `bash poc.sh destruir`.

## Arquivos

| Caminho | O que é |
|---|---|
| `aws/poc-glue-servicenow.yaml` | CloudFormation: bucket, roles, job Glue (com a tag `auto-remediacao=sim`), papel de automação, conexão + API destination da ServiceNow, regra do EventBridge e fila de falhas de entrega |
| `aws/glue/job_travavel.py` | Job Glue que trava uma vez quando existe `controle/travar-proxima-execucao` no bucket |
| `setup/servicenow.yml` + `setup/servicenow/acionar_eda.js` | Configuração da ServiceNow e o script da business rule |
| `setup/aws.yml`, `setup/destruir.yml` | Sobe e remove a stack |
| `rulebooks/servicenow-glue-webhook.yml` | Rulebook do modo CLI (a ServiceNow chama o EDA) |
| `rulebooks/servicenow-glue-polling.yml` | Alternativa sem webhook: o EDA consulta a ServiceNow (só conexões de saída) |
| `rulebooks/servicenow-glue-aap.yml` | Variante para o AAP 2.5 |
| `restart_glue_job.yml` | O playbook de restart |
| `vars/contas.yml` | Catálogo de contas: papel a assumir, ExternalId, regiões, critério de elegibilidade e limite de restarts por conta |
| `library/glue_job_run.py` | Módulo local: iniciar, parar, listar, aguardar e contar execuções do Glue, e ler as tags do job |
| `simular_travamento.yml` | Arma o travamento e inicia o job |
| `poc.sh` | Atalhos de todos os passos |

## Guarda-corpos

- **Catálogo de contas** (`vars/contas.yml`): o Ansible só age em conta, região e job que passem pelas regras do catálogo (tag no job ou lista de jobs), venha o que vier no incidente. Fora delas, anota o motivo no incidente e não mexe no Glue. Conta com o catálogo incompleto (sem papel, sem critério de elegibilidade ou com o critério escrito errado) também é recusada.
- **Papel de automação com menor privilégio:** o Ansible não usa a credencial base direto no Glue; assume o papel `poc-glue-sn-automacao` (com ExternalId), que só alcança os jobs do POC. Iniciar e parar execuções só é permitido pelo IAM em job com a tag `auto-remediacao=sim`, independentemente do catálogo. A credencial temporária não aparece no log do job.
- **Só dois campos do incidente chegam ao playbook:** o rulebook passa o número e o `correlation_id`, e descarta o evento se algum deles tiver chaves (`{` ou `}`) ou se o número fugir do padrão. Sem isso, uma expressão Jinja escrita num campo do incidente seria avaliada pelo Ansible no modo de linha de comando.
- **Limite de restarts:** no máximo 3 por job na última hora (`max_restarts` e `janela_restarts_horas`). Se o restart travar de novo, o novo incidente recebe uma nota de escalação e nada é reiniciado.
- **Incidente duplicado:** o EventBridge reenvia o evento quando a ServiceNow demora mais de 5 s para responder, o que abre um segundo incidente igual. A business rule fecha o repetido como *Duplicate*, vinculado ao original, sem chamar o EDA. Repetido é sempre o incidente criado depois (no empate de segundo, o de maior número): mesmo que as regras dos dois rodem juntas, o mais antigo segue para o EDA. O playbook tem uma segunda proteção: se o job já foi reiniciado depois daquela execução travada, só resolve como duplicado.
- **Só a execução do incidente:** o playbook exige que a execução citada exista e esteja em `TIMEOUT` (`glue_estados_travado`). Ele não para outras execuções do job; se já houver uma execução mais nova em andamento (agendamento, restart manual), anota no incidente e não inicia outra por cima.
- **Origem do incidente:** a business rule (e o rulebook de polling) só aceita incidentes criados pelo usuário de integração. Um incidente aberto por outra pessoa com `correlation_display = aws-glue` não aciona a automação.
- **Falha anotada:** qualquer erro no caminho (API do Glue, limite de execuções simultâneas, ServiceNow) vira uma nota no incidente com a etapa e a mensagem. Se o restart ainda estiver rodando ao fim da espera (`espera_restart_segundos`, 15 min por padrão), a nota diz qual execução acompanhar.
- **Token Bearer** no webhook: chamadas sem o token recebem HTTP 401.
- **Usuário de integração** só para web service (não entra na interface), com os papéis `itil` e `poc_eda`. As propriedades `poc.eda.*` (URL e token do webhook) só são lidas e gravadas por quem tem o `poc_eda`.
- **Falhas de entrega:** eventos que o EventBridge não conseguir entregar à ServiceNow (instância hibernando, senha errada) vão para a fila SQS `poc-glue-sn-falhas-entrega`. Um alarme do CloudWatch dispara quando há mensagem nessa fila e avisa no tópico SNS `poc-glue-sn-alertas` (por e-mail, se `ALERTAS_EMAIL` estiver no `.env`; a assinatura precisa ser confirmada pelo link que a AWS envia).
- **ServiceNow sem resposta do EDA:** a business rule tenta até 3 vezes (falha de rede, timeout ou erro 5xx). Se não conseguir, a nota no incidente diz que o job não foi reiniciado.

## Ambiente montado (29/10/2026)

- **ServiceNow:** PDI de desenvolvimento (release Brazil). Na montagem original, a business rule, as propriedades `poc.eda.*` (com `read_roles`/`write_roles` = `itil`) e o papel `itil` do usuário `poc.integracao.aws` foram configurados pelo console da ServiceNow, logado como admin. Em 12/11/2026 a instância recebeu a configuração atual do `setup/servicenow.yml` (papel `poc_eda` nas propriedades, business rule restrita ao usuário de integração e o script atual), aplicada pela Table API com a sessão do admin; o playbook em si não rodou nessa data. `bash poc.sh url` usa o próprio usuário de integração, sem a senha do admin.
- **Código de resolução:** esta instância não tem "Solution provided"; o POC usa "Workaround provided" (exibido como "Resolved – Workaround Applied").
- **AWS:** conta 123456789012, us-east-1, stack `poc-glue-sn`.
- **`.env`:** é lido literalmente pelo `poc.sh`, então senhas com `>`, `(`, `'` ou `$` funcionam.

Resultado das duas primeiras demos reais:

| Incidente | Execução travada | O que aconteceu |
|---|---|---|
| INC0010001 | TIMEOUT aos 120 s | ServiceNow → EDA em segundos; job reiniciado (SUCCEEDED em 91 s); incidente resolvido |
| INC0010002 | mesma do 0001 | Duplicado criado pelo reenvio do EventBridge. Revelou dois bugs, já corrigidos: duplicidade e a permissão do overwrite (`saida_$folder$`). Encerrado como *Duplicate* |
| INC0010003 | TIMEOUT aos 130 s | Sem duplicado; reiniciado gravando por cima da saída existente (SUCCEEDED em 124 s); resolvido |

## Rodando no AAP 2.7 do lab (aap.lab.example)

Configurado por `setup/aap_lab_configurar.ps1` (idempotente; lê os segredos de `aap-lab/segredos/aap.env`, do `.env` e do perfil `[poc-aap]` da AWS, sem exibi-los).

Duas credenciais ficam no mínimo necessário:

- **AWS:** a credencial "POC AWS" usa a chave do usuário `poc-glue-sn-aap`, criado pela stack, que só pode assumir o papel de automação. Crie a chave uma vez e grave no perfil `[poc-aap]`:
  ```bash
  aws iam create-access-key --user-name poc-glue-sn-aap --profile poc
  ```
- **EDA → Controller:** o EDA lança o job template com o usuário `poc-eda`, que só tem o papel *Execute* nesse template. O script cria o usuário e guarda a senha em `aap.env`. Se a activation já estava rodando com outra credencial, reinicie-a depois. Com `-EdaComAdmin` o script volta a usar o admin.

**Sem PowerShell (Git Bash):** o `setup/aap_configurar.sh` cria os mesmos objetos pela API, só com `curl` e `perl`, em qualquer AAP. Os nomes e endereços vêm de `setup/aap_configurar.conf` (modelo em `aap_configurar.conf.exemplo`), e as senhas são pedidas na hora. Diferenças para o script do lab: ele usa uma credencial da AWS que já exista (não lê chave de arquivo) e não cria o usuário do EDA, só concede o papel *Execute* ao que for informado.

```bash
bash setup/aap_configurar.sh --simular
```

Objetos criados:

| Onde | Objeto |
|---|---|
| Controller | credenciais "POC AWS" e "POC ServiceNow" (tipo próprio que injeta `SN_HOST`/`SN_INTEGRACAO_SENHA`), projeto "POC Glue ServiceNow", inventário "POC localhost", job template **poc-restart-glue-job** (EE "Hub Default") |
| EDA | credencial "POC ServiceNow token" (tipo *ServiceNow Event Stream*; o EDA tira o `Bearer ` do cabeçalho), Event Stream **poc-servicenow-glue**, credencial "POC AAP controller", activation **poc-servicenow-glue-restart** (DE "Hub Default") |
| VM | Git *smart HTTP* só leitura em `http://<ip-da-vm>:8090/cgi-bin/git/poc-glue-servicenow.git` (serviço `poc-git-http`; o firewall da VM bloqueia de fora). Para publicar mudanças: copiar para `~/src/poc-glue-servicenow`, `git commit` e `git push lab main`, depois rodar o script de novo |

No rulebook do AAP, o `run_job_template` passa só `incidente_numero` e `correlation_id` em `job_args.extra_vars`. Assim o job template também pode ser lançado à mão no AAP com essas duas variáveis.

Validado no lab: token errado → 403; token certo → 200, o EDA lançou o job e ele parou na lista de jobs permitidos (incidente de teste com job não permitido).

Para a ServiceNow alcançar o Event Stream, o túnel roda na VM (o WSL não alcança a rede do lab):

```powershell
& "$env:SystemRoot\System32\OpenSSH\ssh.exe" -i "$env:USERPROFILE\.ssh\aap-lab" aap@<ip-da-vm> "~/bin/cloudflared tunnel --no-autoupdate --url https://localhost:443 --no-tls-verify --http-host-header aap.lab.example"
```

Depois, grave a URL na ServiceNow com `bash poc.sh url-aap https://<nome>.trycloudflare.com`. O comando acrescenta o caminho do Event Stream (`event_stream_caminho.txt`) e, antes de gravar, confere que a URL recusa um token errado (403). Só o endereço do túnel, sem o caminho, responde 405 e não é gravado.

## Levar para o AAP do lab (referência)

1. Publique esta pasta num Git que o AAP alcance.
2. No controller:
   - projeto apontando para o Git;
   - credencial *Amazon Web Services*;
   - credencial customizada que injete as variáveis de ambiente `SN_HOST` e `SN_INTEGRACAO_SENHA`;
   - job template `poc-restart-glue-job` com `restart_glue_job.yml` e *Prompt on launch* nas variáveis.
3. No EDA:
   - um *Event Stream* do tipo token;
   - uma rulebook activation com `rulebooks/servicenow-glue-aap.yml` ligada a esse event stream e com a credencial do AAP.
4. Rode `bash poc.sh url-aap <endereço do AAP ou do túnel>` (ou `bash poc.sh url <URL completa do event stream>`). A ServiceNow precisa alcançar essa URL; num lab fechado, isso exige túnel, proxy reverso ou MID Server. Se não der, use o rulebook de polling, que só faz conexões de saída.

## Várias contas e assume role

O playbook não depende de conta nem de região fixas: tudo vem do incidente.

- **`correlation_id = <conta>|<região>|<job>|<execução>`**: a regra do EventBridge monta esse valor com os campos `account` e `region` do próprio evento do Glue. Se outra integração abrir o incidente, ela precisa preencher o campo no mesmo formato.
- **Catálogo de contas** (`vars/contas.yml`): para cada conta, o papel a assumir, o ExternalId, as regiões liberadas, o critério de elegibilidade (`tag` ou `lista`) e, se quiser, um `max_restarts` próprio. Conta nova = uma entrada no catálogo e o papel criado na conta.
- **Assume role:** o Ansible se autentica com a credencial base (no AAP, a credencial "POC AWS") e assume `arn:aws:iam::<conta>:role/<papel_automacao>` em cada execução. Todas as chamadas ao Glue usam a credencial temporária (`module_defaults`).
- **Elegibilidade por tag:** com `elegibilidade: tag`, o job precisa ter a tag `auto-remediacao=sim` (configurável por conta). Com `lista`, precisa estar em `jobs_permitidos` da conta.

Quando o incidente não passa nas regras, o Ansible anota o motivo no incidente ("A automação não atuou: ...") e para, sem chamar o Glue:

| Situação | Motivo anotado |
|---|---|
| `correlation_id` em outro formato | fora do formato conta\|região\|job\|execução |
| Conta fora do catálogo | a conta não está no catálogo de contas da automação |
| Região não liberada para a conta | a região não está liberada para a conta |
| Job inexistente na conta e região | o job não existe na conta |
| Job sem a tag (ou fora da lista) | o job não tem a tag / não está na lista de jobs permitidos |
| Execução inexistente no job | a execução não foi encontrada no job |
| Execução que não travou | a execução está em (estado), e não em TIMEOUT |
| Execução mais nova em andamento | o job já tem execução mais nova em andamento; nada foi parado nem reiniciado |

Quando o papel não pode ser assumido (conta nova sem o papel, ExternalId diferente do catálogo), o motivo também vai para o incidente: "não foi possível assumir o papel ... (AccessDenied)".

**Limite de 100 caracteres:** o `correlation_id` da ServiceNow guarda no máximo 100 caracteres. Conta (12) + região + job + ID da execução (67) passa disso, e a ServiceNow corta o fim do ID da execução. O módulo `glue_job_run` aceita o ID cortado: procura a execução que começa com aquele prefixo e só segue se houver exatamente uma. Com nomes de job longos, vale confirmar quanto sobra do ID (ou usar um campo próprio para a execução).

Validado no laboratório (04/11/2026): os seis motivos de recusa acima e o papel não assumido, pela CLI; e, pelo AAP (EE com ansible-core 2.16), o restart de ponta a ponta com o ID cortado (INC0010016, resolvido em 106 s) e o incidente duplicado da mesma execução, resolvido como *Duplicate* sem novo restart.

Validado de novo em 12/11/2026, com a stack, a ServiceNow e o AAP na versão atual:

- **Fluxo principal:** job travado (TIMEOUT aos 130 s) → o EventBridge abriu o INC0010019 → o EDA lançou o job template → restart pelo papel de automação (SUCCEEDED em 72 s) → incidente resolvido. O job do AAP levou 99 s, e a credencial temporária não apareceu no log.
- **Recusas pelo AAP**, anotadas no incidente de teste: formato do `correlation_id`, conta fora do catálogo, região não liberada, job inexistente, execução inexistente e execução que não travou. O evento repetido de uma execução já reiniciada fechou o incidente como *Duplicate*, sem novo restart.
- **Rulebook** (AAP e linha de comando): token errado recusado (403 no Event Stream, 401 no webhook local); eventos com chaves no número ou no `correlation_id`, número fora do padrão e descrição sem "AWS Glue" foram descartados sem lançar job.
- **Business rule:** três tentativas e a nota de falha quando o EDA não responde; incidente repetido fechado como *Duplicate*, vinculado ao original; incidente sem `correlation_id` anotado; incidente aberto por outro usuário ignorado.
- **Propriedades `poc.eda.*`:** o usuário de integração lê e grava com o papel `poc_eda`, e não enxerga outras propriedades.

- **Com o túnel, sem intervenção:** `bash poc.sh url-aap` gravou a URL (403 conferido antes) e um segundo travamento percorreu o caminho inteiro. O INC0010024 foi aberto, a business rule acionou o EDA 6 s depois (HTTP 200, na primeira tentativa), o job do AAP levou 140 s e o incidente foi resolvido 3 min 8 s após a abertura, sem duplicado.

Os cenários de recusa e o INC0010019 foram entregues ao Event Stream pela rede do lab, com o mesmo corpo que a business rule envia. Ficaram de fora o limite de restarts, a credencial "POC AWS" com a chave do usuário `poc-glue-sn-aap` e o usuário `poc-eda` (o EDA lançou o job como admin).

O teste revelou um defeito, já corrigido: a business rule gravava a nota de trabalho com `setValue`, que não cria a entrada no campo de diário; a nota não aparecia no incidente.

O papel do POC (`poc-glue-sn-automacao`, criado pela stack) confia nas identidades da própria conta e exige o ExternalId `poc-glue-sn-aap`. Para restringir a um principal só (o do AAP), passe o ARN no parâmetro `PrincipalAutomacao` da stack. Permissões do papel, só nos jobs `poc-glue-sn-*`: consultas (`glue:GetJob`, `glue:GetJobRun`, `glue:GetJobRuns`, `glue:GetTags`) em qualquer um deles; `glue:StartJobRun` e `glue:BatchStopJobRun` apenas nos que têm a tag `auto-remediacao=sim` (condição `aws:ResourceTag`). Não precisa de `iam:PassRole`.

## Para produção

- OAuth na conexão do EventBridge e no Ansible, em vez de Basic auth.
- Token do webhook numa propriedade criptografada (`password2`) e HMAC ou mTLS no lugar do Bearer simples.
- MID Server ou o *Ansible Spoke* da ServiceNow em vez de túnel.
- Detecção de "travado" além do timeout (ex.: execução sem progresso há X minutos) com uma regra agendada.

## Permissões mínimas do usuário AWS

`bash poc.sh aws` (criar a stack) precisa de permissões de administração no lab. Para só rodar o restart, a credencial base só precisa assumir o papel de automação, que tem as permissões do Glue (seção *Várias contas e assume role*). A stack já cria um usuário com exatamente esta política, `poc-glue-sn-aap`, para a credencial do AAP:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow", "Action": "sts:AssumeRole", "Resource": "arn:aws:iam::<conta>:role/poc-glue-sn-automacao"}
  ]
}
```

Sem assume role (o modelo antigo do POC), as permissões do Glue iriam direto na credencial base:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {"Effect": "Allow",
     "Action": ["glue:GetJob", "glue:GetJobRun", "glue:GetJobRuns", "glue:StartJobRun", "glue:BatchStopJobRun"],
     "Resource": "arn:aws:glue:us-east-1:<conta>:job/poc-glue-sn-carga-diaria"}
  ]
}
```

## Como foi validado

Antes de usar as contas reais, foi validado:
- `ansible-playbook --syntax-check` e `ansible-lint` (perfil *production*, sem avisos);
- `cfn-lint` no template CloudFormation;
- os três rulebooks contra o schema oficial do ansible-rulebook;
- sintaxe do JavaScript da business rule;
- **ponta a ponta local:** `ansible-rulebook` real com o webhook, chamado como a ServiceNow chamaria, com Glue e ServiceNow simulados. Foram 5 cenários:
  - reinicia e resolve;
  - para a execução presa antes de reiniciar;
  - restart que falha (anota e escala);
  - limite de restarts;
  - job fora da lista de permitidos;
  - e o token errado recebe 401;
- o módulo `glue_job_run` contra um Glue simulado (moto): iniciar com timeout por execução, contar restarts, listar ativas.

Depois disso, o POC rodou contra a ServiceNow e a AWS reais, primeiro em linha de comando e depois no AAP do lab. Os ajustes que isso exigiu (código de resolução, duplicados e permissão de sobrescrita no S3) estão na seção *Ambiente montado*.

## Versão para um repositório de automação já existente

A pasta `para-copiar/` traz o playbook, o módulo e o rulebook no layout de um repositório de automação
(`playbooks/`, `plugins/modules/`, `rulebooks/`), com o rulebook lendo o evento de um monitoramento de jobs
em vez do incidente da ServiceNow. Comece pelo `para-copiar/_LEIA-ME.md`.
