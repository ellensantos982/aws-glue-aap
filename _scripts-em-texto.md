# Scripts em texto

Os arquivos `.sh` e `.py` deste repositório, em texto, para ambientes em que o download desses tipos de arquivo não passa.
Cada bloco é o conteúdo de um arquivo, sem a primeira linha quando ela indica o interpretador; o marcador acima do bloco
diz qual era (`bash`: `/usr/bin/env bash`; `python`: `/usr/bin/python`; `nenhum`: o arquivo não tem essa linha).

Gerado a partir dos arquivos do repositório. Não edite à mão.

## aws/glue/job_travavel.py

<!-- arquivo: aws/glue/job_travavel.py | interpretador: nenhum -->
````python
"""Job Glue do POC: uma carga simples que pode "travar" de propósito.

Se existir s3://<bucket>/controle/travar-proxima-execucao, o job apaga o marcador
e fica parado até o Glue encerrá-lo por timeout (estado TIMEOUT). É uma falha
injetada uma única vez, como um travamento transitório real (conexão presa,
executor perdido): a execução seguinte, disparada pelo restart do Ansible, roda normal.
"""
import sys
import time

import boto3
from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from botocore.exceptions import ClientError
from pyspark.context import SparkContext
from pyspark.sql import functions as F

args = getResolvedOptions(sys.argv, ["JOB_NAME", "bucket"])
MARCADOR = "controle/travar-proxima-execucao"

sc = SparkContext()
glue_context = GlueContext(sc)
spark = glue_context.spark_session
job = Job(glue_context)
job.init(args["JOB_NAME"], args)

s3 = boto3.client("s3")
try:
    s3.head_object(Bucket=args["bucket"], Key=MARCADOR)
    travar = True
except ClientError:
    travar = False

if travar:
    s3.delete_object(Bucket=args["bucket"], Key=MARCADOR)
    print("Marcador encontrado: simulando travamento até o timeout do Glue")
    while True:
        time.sleep(30)

# Carga normal: gera um resumo pequeno e grava com overwrite (reexecutar é seguro)
resumo = (
    spark.range(0, 10000)
    .withColumn("estabelecimento", F.concat(F.lit("EST"), (F.col("id") % 20).cast("string")))
    .groupBy("estabelecimento")
    .agg(F.count("*").alias("qtd_transacoes"))
)
resumo.write.mode("overwrite").parquet(f"s3://{args['bucket']}/saida/carga-diaria/")

job.commit()
````

## library/glue_job_run.py

<!-- arquivo: library/glue_job_run.py | interpretador: python -->
````python
# -*- coding: utf-8 -*-
# Módulo local do POC: as coleções amazon.aws/community.aws criam o job Glue,
# mas não iniciam, param nem consultam execuções. Usa só boto3, que já vem no EE padrão do AAP.

DOCUMENTATION = r"""
---
module: glue_job_run
short_description: Inicia, para, aguarda e consulta execuções de um job AWS Glue
description:
  - C(info) devolve a execução e os argumentos efetivos (padrões do job + argumentos da execução).
  - C(running) lista as execuções ainda ativas (STARTING, RUNNING, STOPPING, WAITING); com I(after_run_id), só as mais novas que ela.
  - C(stop) para as execuções informadas e aguarda que parem. Execução que já terminou não é erro.
  - C(start) inicia uma nova execução.
  - C(wait) aguarda uma execução terminar.
  - C(count) conta execuções numa janela de horas que tenham um argumento com certo valor.
  - C(tags) devolve as tags do job (para decidir se a automação pode agir nele).
options:
  action:
    description: O que fazer.
    type: str
    required: true
    choices: [info, running, stop, start, wait, count, tags]
  job_name:
    description: Nome do job Glue.
    type: str
    required: true
  run_id:
    description: ID da execução (para C(info) e C(wait)).
    type: str
  run_ids:
    description: IDs das execuções a parar (para C(stop)).
    type: list
    elements: str
    default: []
  arguments:
    description: Argumentos da execução (para C(start)).
    type: dict
    default: {}
  number_of_workers:
    description: Quantidade de workers (para C(start)). Exige I(worker_type).
    type: int
  worker_type:
    description: Tipo de worker, por exemplo C(G.1X) (para C(start)).
    type: str
  job_timeout:
    description: Timeout desta execução em minutos (para C(start)). Sem ele, vale o do job.
    type: int
  timeout:
    description: Segundos máximos de espera (para C(wait) e C(stop)).
    type: int
    default: 900
  argument_name:
    description: Argumento a filtrar (para C(count)).
    type: str
    default: --dt
  argument_value:
    description: Valor do argumento a contar (para C(count)).
    type: str
  hours:
    description: Janela em horas (para C(count)).
    type: int
    default: 24
  after_run_id:
    description:
      - Em C(count), só conta execuções iniciadas depois que esta execução terminou.
      - Em C(running), só lista execuções iniciadas depois do início desta execução.
    type: str
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
"""

EXAMPLES = r"""
- name: Listar execuções ativas
  glue_job_run:
    action: running
    job_name: poc-glue-sn-carga-diaria
  register: ativas

- name: Parar as execuções travadas
  glue_job_run:
    action: stop
    job_name: poc-glue-sn-carga-diaria
    run_ids: "{{ ativas.runs | map(attribute='Id') | list }}"

- name: Reiniciar
  glue_job_run:
    action: start
    job_name: poc-glue-sn-carga-diaria
    arguments: {"--origem": "ansible-restart"}
  register: novo
"""

RETURN = r"""
job_run:
  description: Dados da execução (info, wait).
  returned: when action is info or wait
  type: dict
arguments_efetivos:
  description: DefaultArguments do job sobrepostos pelos Arguments da execução.
  returned: when action is info
  type: dict
runs:
  description: Execuções ativas (running) ou paradas (stop).
  returned: when action is running or stop
  type: list
run_id:
  description: ID da execução iniciada.
  returned: when action is start
  type: str
count:
  description: Execuções encontradas na janela.
  returned: when action is count
  type: int
tags:
  description: Tags do job (vazio se o job não existir).
  returned: when action is tags
  type: dict
encontrado:
  description: Se o job existe na conta e região.
  returned: when action is tags
  type: bool
"""

import datetime
import time

try:
    import botocore
except ImportError:
    pass  # tratado pelo AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule

ESTADOS_FINAIS = ("SUCCEEDED", "FAILED", "TIMEOUT", "STOPPED", "ERROR")
ESTADOS_ATIVOS = ("STARTING", "RUNNING", "STOPPING", "WAITING")


def serializavel(obj):
    if isinstance(obj, dict):
        return {k: serializavel(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [serializavel(v) for v in obj]
    if isinstance(obj, datetime.datetime):
        return obj.isoformat()
    return obj


def obter_execucao(glue, job_name, run_id):
    # O correlation_id da ServiceNow tem 100 caracteres: com conta, região e um nome de job longo,
    # o ID da execução chega cortado. Nesse caso vale o prefixo, se ele for de uma execução só.
    try:
        return glue.get_job_run(JobName=job_name, RunId=run_id)["JobRun"]
    except (glue.exceptions.EntityNotFoundException, glue.exceptions.InvalidInputException):
        candidatas = [e for e in execucoes(glue, job_name) if e["Id"].startswith(run_id)]
        if len(candidatas) != 1:
            raise
        return candidatas[0]


def execucoes(glue, job_name):
    for pagina in glue.get_paginator("get_job_runs").paginate(JobName=job_name):
        yield from pagina["JobRuns"]


def aguardar(module, glue, job_name, run_id, estados, limite):
    execucao = obter_execucao(glue, job_name, run_id)
    while execucao["JobRunState"] not in estados:
        if time.time() > limite:
            module.fail_json(
                msg=f"Execução {run_id} ainda em {execucao['JobRunState']} após {module.params['timeout']}s",
                job_run=serializavel(execucao),
            )
        time.sleep(10)
        execucao = obter_execucao(glue, job_name, run_id)
    return execucao


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            action=dict(type="str", required=True, choices=["info", "running", "stop", "start", "wait", "count", "tags"]),
            job_name=dict(type="str", required=True),
            run_id=dict(type="str"),
            run_ids=dict(type="list", elements="str", default=[]),
            arguments=dict(type="dict", default={}),
            number_of_workers=dict(type="int"),
            worker_type=dict(type="str"),
            job_timeout=dict(type="int"),
            timeout=dict(type="int", default=900),
            argument_name=dict(type="str", default="--dt"),
            argument_value=dict(type="str"),
            hours=dict(type="int", default=24),
            after_run_id=dict(type="str"),
        ),
        required_if=[
            ("action", "info", ["run_id"]),
            ("action", "wait", ["run_id"]),
            ("action", "count", ["argument_value"]),
        ],
        required_together=[("number_of_workers", "worker_type")],
        supports_check_mode=True,
    )
    p = module.params
    glue = module.client("glue")

    try:
        if p["action"] == "info":
            execucao = obter_execucao(glue, p["job_name"], p["run_id"])
            padroes = glue.get_job(JobName=p["job_name"])["Job"].get("DefaultArguments", {})
            efetivos = dict(padroes)
            efetivos.update(execucao.get("Arguments", {}))
            module.exit_json(changed=False, job_run=serializavel(execucao), arguments_efetivos=efetivos)

        if p["action"] == "running":
            ativas = [e for e in execucoes(glue, p["job_name"]) if e["JobRunState"] in ESTADOS_ATIVOS]
            if p["after_run_id"]:
                referencia = obter_execucao(glue, p["job_name"], p["after_run_id"])
                ativas = [e for e in ativas if e["Id"] != referencia["Id"] and e["StartedOn"] > referencia["StartedOn"]]
            module.exit_json(changed=False, runs=serializavel(ativas))

        if p["action"] == "stop":
            if not p["run_ids"]:
                module.exit_json(changed=False, runs=[])
            if module.check_mode:
                module.exit_json(changed=True, runs=[])
            resposta = glue.batch_stop_job_run(JobName=p["job_name"], JobRunIds=p["run_ids"])
            # Execução que terminou entre a consulta e a parada volta como erro: só falha se continuar ativa
            pendentes = [
                erro for erro in resposta.get("Errors", [])
                if obter_execucao(glue, p["job_name"], erro["JobRunId"])["JobRunState"] not in ESTADOS_FINAIS
            ]
            if pendentes:
                module.fail_json(msg="Falha ao parar execuções", errors=serializavel(pendentes))
            limite = time.time() + p["timeout"]
            paradas = [aguardar(module, glue, p["job_name"], r, ESTADOS_FINAIS, limite) for r in p["run_ids"]]
            module.exit_json(changed=True, runs=serializavel(paradas))

        if p["action"] == "start":
            if module.check_mode:
                module.exit_json(changed=True, run_id=None)
            pedido = {"JobName": p["job_name"], "Arguments": {k: str(v) for k, v in p["arguments"].items()}}
            if p["number_of_workers"]:
                pedido["NumberOfWorkers"] = p["number_of_workers"]
                pedido["WorkerType"] = p["worker_type"]
            if p["job_timeout"]:
                pedido["Timeout"] = p["job_timeout"]
            run_id = glue.start_job_run(**pedido)["JobRunId"]
            module.exit_json(changed=True, run_id=run_id)

        if p["action"] == "wait":
            execucao = aguardar(module, glue, p["job_name"], p["run_id"], ESTADOS_FINAIS, time.time() + p["timeout"])
            module.exit_json(changed=False, job_run=serializavel(execucao))

        if p["action"] == "count":
            desde = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=p["hours"])
            if p["after_run_id"]:
                referencia = obter_execucao(glue, p["job_name"], p["after_run_id"])
                desde = max(desde, referencia.get("CompletedOn") or referencia["StartedOn"])
            encontradas = [
                {"id": e["Id"], "estado": e["JobRunState"], "inicio": e["StartedOn"].isoformat()}
                for e in execucoes(glue, p["job_name"])
                if e["StartedOn"] >= desde and e.get("Arguments", {}).get(p["argument_name"]) == p["argument_value"]
            ]
            module.exit_json(changed=False, count=len(encontradas), execucoes=encontradas)

        if p["action"] == "tags":
            # O ARN do job usa a conta e a região da credencial em uso (a do papel assumido)
            identidade = module.client("sts").get_caller_identity()
            particao, conta = identidade["Arn"].split(":")[1], identidade["Account"]
            arn = f"arn:{particao}:glue:{module.region}:{conta}:job/{p['job_name']}"
            try:
                glue.get_job(JobName=p["job_name"])
            except glue.exceptions.EntityNotFoundException:
                module.exit_json(changed=False, tags={}, encontrado=False)
            module.exit_json(changed=False, tags=glue.get_tags(ResourceArn=arn).get("Tags", {}), encontrado=True)

    except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
        module.fail_json_aws(e, msg=f"Falha na chamada ao Glue ({p['action']})")


if __name__ == "__main__":
    main()
````

## para-copiar/_ferramentas/aap_configurar.sh

<!-- arquivo: para-copiar/_ferramentas/aap_configurar.sh | interpretador: bash -->
````bash
# Configura no AAP, pela API, os objetos do fluxo ServiceNow -> EDA -> restart do job Glue.
# Roda em qualquer bash com curl e perl; no Windows, o Git Bash já traz os dois.
# Idempotente: pode rodar de novo.
#
#   bash setup/aap_configurar.sh [--simular] [arquivo.conf]
#
#   --simular   só consulta o AAP e mostra o que seria criado ou atualizado
#   arquivo     padrão: aap_configurar.conf, ao lado deste script (modelo: aap_configurar.conf.exemplo)
#
# O arquivo de configuração não guarda segredos. Eles são pedidos na hora, sem eco, ou vêm
# destas variáveis de ambiente:
#   AAP_SENHA             senha de AAP_USUARIO
#   AAP_TOKEN             token de API do AAP, no lugar de usuário e senha
#   SN_INTEGRACAO_SENHA   senha do usuário de integração da ServiceNow
#   EDA_TOKEN             token que a ServiceNow envia ao Event Stream
#   EDA_CONTROLLER_SENHA  senha de EDA_CONTROLLER_USUARIO
# Segredo em branco mantém a credencial que já existe no AAP.
#
# Cria: no Controller, o tipo de credencial e a credencial da ServiceNow, o projeto, o inventário
# e o job template; no EDA, as credenciais, o Event Stream, o projeto e a rulebook activation.
# Nenhum segredo vai para a linha de comando de outro programa nem para arquivo.
set -euo pipefail

erro() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
aviso() { printf 'AVISO: %s\n' "$*" >&2; }

SIMULAR=0
ARQUIVO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/aap_configurar.conf"
for arg in "$@"; do
    case $arg in
        --simular) SIMULAR=1 ;;
        -h | --help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) erro "opção desconhecida: $arg" ;;
        *) ARQUIVO=$arg ;;
    esac
done

command -v curl > /dev/null || erro "curl não encontrado."
perl -MJSON::PP -e 1 2> /dev/null || erro "perl com o módulo JSON::PP não encontrado (o Git Bash completo traz os dois)."

# ---------------- Configuração ----------------
CHAVES=" AAP_URL AAP_USUARIO AAP_TLS_INSEGURO AAP_ORGANIZACAO REPO_GIT REPO_BRANCH
 REPO_CREDENCIAL_CONTROLLER REPO_CREDENCIAL_EDA PLAYBOOK RULEBOOK EXECUTION_ENVIRONMENT
 DECISION_ENVIRONMENT AWS_CREDENCIAL SN_HOST EDA_CONTROLLER_USUARIO NOME_TIPO_CREDENCIAL_SN
 NOME_CREDENCIAL_SN NOME_PROJETO NOME_INVENTARIO NOME_JOB_TEMPLATE NOME_CREDENCIAL_EDA_CONTROLLER
 NOME_CREDENCIAL_EDA_TOKEN NOME_EVENT_STREAM NOME_ACTIVATION "

[[ -f $ARQUIVO ]] || erro "arquivo de configuração não encontrado: $ARQUIVO (copie o aap_configurar.conf.exemplo)"
# Lê CHAVE=valor sem executar o arquivo; o que já veio do ambiente tem prioridade
while IFS= read -r linha || [[ -n $linha ]]; do
    linha=${linha%$'\r'}
    [[ $linha =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    chave=${BASH_REMATCH[1]}
    valor=${BASH_REMATCH[2]}
    valor=${valor%"${valor##*[![:space:]]}"}
    [[ $CHAVES == *[[:space:]]"$chave"[[:space:]]* ]] || { aviso "chave ignorada no arquivo: $chave"; continue; }
    [[ -n ${!chave-} ]] || printf -v "$chave" '%s' "$valor"
done < "$ARQUIVO"

: "${AAP_URL:=}" "${AAP_USUARIO:=}" "${AAP_TLS_INSEGURO:=nao}" "${AAP_ORGANIZACAO:=Default}"
: "${REPO_GIT:=}" "${REPO_BRANCH:=main}" "${REPO_CREDENCIAL_CONTROLLER:=}" "${REPO_CREDENCIAL_EDA:=}"
: "${PLAYBOOK:=playbooks/restart_glue_job.yml}" "${RULEBOOK:=servicenow-glue-aap.yml}"
: "${EXECUTION_ENVIRONMENT:=}" "${DECISION_ENVIRONMENT:=}" "${AWS_CREDENCIAL:=}" "${SN_HOST:=}"
: "${EDA_CONTROLLER_USUARIO:=}"
: "${NOME_TIPO_CREDENCIAL_SN:=POC ServiceNow (integracao)}" "${NOME_CREDENCIAL_SN:=POC ServiceNow}"
: "${NOME_PROJETO:=POC Glue ServiceNow}" "${NOME_INVENTARIO:=POC localhost}"
: "${NOME_JOB_TEMPLATE:=poc-restart-glue-job}" "${NOME_CREDENCIAL_EDA_CONTROLLER:=POC AAP controller}"
: "${NOME_CREDENCIAL_EDA_TOKEN:=POC ServiceNow token}" "${NOME_EVENT_STREAM:=poc-servicenow-glue}"
: "${NOME_ACTIVATION:=poc-servicenow-glue-restart}"
: "${AAP_SENHA:=}" "${AAP_TOKEN:=}" "${SN_INTEGRACAO_SENHA:=}" "${EDA_TOKEN:=}" "${EDA_CONTROLLER_SENHA:=}"

AAP_URL=${AAP_URL%/}
for obrigatoria in AAP_URL REPO_GIT EXECUTION_ENVIRONMENT DECISION_ENVIRONMENT SN_HOST; do
    [[ -n ${!obrigatoria} ]] || erro "falta $obrigatoria em $ARQUIVO"
done
[[ $AAP_URL == https://* || $AAP_URL == http://* ]] || erro "AAP_URL precisa começar com https://"

CURL_OPCOES=(--connect-timeout 15 --max-time 90)
VERIFICAR_TLS=true
if [[ $AAP_TLS_INSEGURO == sim ]]; then
    CURL_OPCOES+=(-k)
    VERIFICAR_TLS=false
fi

# Usa a variável de ambiente; se estiver vazia e houver terminal, pergunta sem eco
pedir() {
    local valor=${!1-}
    if [[ -z $valor && -t 0 ]]; then
        read -rs -p "$2: " valor || true
        echo >&2
    fi
    printf -v "$1" '%s' "$valor"
}

if [[ -n $AAP_TOKEN ]]; then
    AUTORIZACAO="Bearer $AAP_TOKEN"
else
    [[ -n $AAP_USUARIO ]] || erro "falta AAP_USUARIO em $ARQUIVO (ou a variável de ambiente AAP_TOKEN)"
    pedir AAP_SENHA "Senha de $AAP_USUARIO no AAP"
    [[ -n $AAP_SENHA ]] || erro "senha do AAP não informada"
    AUTORIZACAO="Basic $(printf '%s' "$AAP_USUARIO:$AAP_SENHA" | base64 | tr -d '\r\n')"
fi

# ---------------- JSON (perl) e HTTP (curl) ----------------
# obj chave=texto chave:=json ...  -> objeto JSON. Os valores chegam ao perl pela entrada padrão.
obj() {
    printf '%s\0' "$@" | perl -MJSON::PP -0 -e '
        my $j = JSON::PP->new->utf8->allow_nonref; my %o;
        while (defined(my $a = <STDIN>)) {
            chomp $a;
            if ($a =~ /^([^=:]+):=(.*)$/s) { $o{$1} = length $2 ? $j->decode($2) : undef }
            elsif ($a =~ /^([^=:]+)=(.*)$/s) { my ($k, $v) = ($1, $2); utf8::decode($v); $o{$k} = $v }
            else { die "argumento invalido para obj\n" }
        }
        print JSON::PP->new->utf8->canonical->encode(\%o);'
}

# campo <json> <caminho.com.pontos>  -> valor (vazio se não existir)
campo() {
    printf '%s' "$1" | perl -MJSON::PP -0777 -e '
        my $j = JSON::PP->new->utf8->allow_nonref->canonical;
        my $d = eval { $j->decode(scalar <STDIN>) };
        for my $k (split /\./, $ARGV[0]) {
            if (ref $d eq "HASH") { $d = $d->{$k} }
            elsif (ref $d eq "ARRAY" && $k =~ /^\d+$/) { $d = $d->[$k] }
            else { exit 0 }
        }
        exit 0 unless defined $d;
        if (ref $d) { print $j->encode($d) } else { utf8::encode($d); print $d }' "$2"
}

# achar <json da lista> <campo> <valor>  -> JSON do primeiro item de "results" com campo == valor
achar() {
    printf '%s' "$1" | CAMPO=$2 VALOR=$3 perl -MJSON::PP -0777 -e '
        my $j = JSON::PP->new->utf8->canonical;
        my $d = eval { $j->decode(scalar <STDIN>) };
        exit 0 unless ref $d eq "HASH" && ref $d->{results} eq "ARRAY";
        my ($c, $v) = @ENV{qw(CAMPO VALOR)}; utf8::decode($v);
        for my $r (@{ $d->{results} }) {
            next unless ref $r eq "HASH" && defined $r->{$c} && !ref $r->{$c} && $r->{$c} eq $v;
            print $j->encode($r); last;
        }'
}

urlenc() { printf '%s' "$1" | perl -pe 's/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge'; }

# api <MÉTODO> <caminho> [corpo]  -> resposta em RESP, código HTTP em STATUS.
# Cabeçalho e corpo vão ao curl pela entrada padrão (-K -).
api() {
    local metodo=$1 caminho=$2 corpo=${3-} cfg saida
    cfg="url = \"$AAP_URL$caminho\""$'\n'"request = \"$metodo\""
    cfg+=$'\n'"header = \"Authorization: $AUTORIZACAO\""$'\n''header = "Accept: application/json"'
    if [[ -n $corpo ]]; then
        corpo=${corpo//\\/\\\\}
        corpo=${corpo//\"/\\\"}
        cfg+=$'\n''header = "Content-Type: application/json"'$'\n'"data-binary = \"$corpo\""
    fi
    if ! saida=$(printf '%s\n' "$cfg" | curl -sS -K - "${CURL_OPCOES[@]}" -w '\n%{http_code}'); then
        erro "sem resposta de $AAP_URL$caminho"
    fi
    STATUS=${saida##*$'\n'}
    RESP=${saida%$'\n'*}
}

exigir() { [[ $STATUS == 2* ]] || erro "$1: HTTP $STATUS ${RESP:0:400}"; }

# buscar <api> <valor> [campo]  -> JSON do objeto em OBJ (vazio se não existir)
buscar() {
    local campo_busca=${3:-name}
    api GET "$1?$campo_busca=$(urlenc "$2")"
    exigir "consulta a $1"
    OBJ=$(achar "$RESP" "$campo_busca" "$2")
}

# id_de <variável> <api> <nome> <descrição> [campo]  -> id de algo que precisa existir
id_de() {
    buscar "$2" "$3" "${5:-name}"
    [[ -n $OBJ ]] || erro "não encontrei $4 '$3' no AAP"
    printf -v "$1" '%s' "$(campo "$OBJ" id)"
}

# garantir <variável> <api> <nome> <corpo> [manter]  -> cria pelo nome ou atualiza; id na variável.
# Com "manter", o que já existe não é alterado. Na simulação, o id de algo que não existe fica vazio.
garantir() {
    local var=$1 caminho=$2 nome=$3 corpo=$4 modo=${5-} id
    buscar "$caminho" "$nome"
    if [[ -z $OBJ ]]; then
        if ((SIMULAR)); then
            echo "  criaria:     $nome"
            printf -v "$var" '%s' ''
            return 0
        fi
        api POST "$caminho" "$corpo"
        # alguns endpoints respondem à criação com redirecionamento: relê pelo nome
        [[ $STATUS == [23]* ]] || erro "criar '$nome': HTTP $STATUS ${RESP:0:400}"
        buscar "$caminho" "$nome"
        [[ -n $OBJ ]] || erro "'$nome' foi criado, mas não apareceu na consulta"
        echo "  criado:      $nome"
    elif [[ $modo == manter ]]; then
        echo "  já existe:   $nome"
    elif ((SIMULAR)); then
        echo "  atualizaria: $nome"
    else
        id=$(campo "$OBJ" id)
        api PATCH "$caminho$id/" "$corpo"
        exigir "atualizar '$nome'"
        echo "  atualizado:  $nome"
    fi
    printf -v "$var" '%s' "$(campo "$OBJ" id)"
}

# garantir_com_segredo <variável> <api> <nome> <segredo> <corpo>
# Sem o segredo, a credencial que já existe fica como está; se não existir, é erro.
garantir_com_segredo() {
    if [[ -n $4 ]]; then
        garantir "$1" "$2" "$3" "$5"
        return 0
    fi
    buscar "$2" "$3"
    if [[ -z $OBJ ]]; then
        ((SIMULAR)) || erro "'$3' ainda não existe: informe o segredo para criar"
        echo "  criaria:     $3"
    else
        echo "  mantido:     $3 (segredo não informado)"
    fi
    printf -v "$1" '%s' "$(campo "$OBJ" id)"
}

# ---------------- Acesso ----------------
if [[ -n $AAP_TOKEN && -z $EDA_CONTROLLER_USUARIO ]]; then
    erro "com AAP_TOKEN, defina EDA_CONTROLLER_USUARIO: o EDA precisa de usuário e senha para lançar o job template"
fi
((SIMULAR)) && echo "SIMULAÇÃO: só consultas; nada é criado nem alterado."
api GET "/api/gateway/v1/me/"
case $STATUS in
    2*) echo "AAP: $AAP_URL (usuário $(campo "$RESP" results.0.username))" ;;
    401 | 403) erro "o AAP recusou a autenticação (HTTP $STATUS)" ;;
    *) erro "resposta inesperada de $AAP_URL/api/gateway/v1/me/: HTTP $STATUS" ;;
esac

if ((!SIMULAR)); then
    pedir SN_INTEGRACAO_SENHA "Senha do usuário de integração da ServiceNow (Enter mantém a atual)"
    pedir EDA_TOKEN "Token que a ServiceNow envia ao Event Stream (Enter mantém o atual)"
fi
# Usuário com que o EDA lança o job template
if [[ -n $EDA_CONTROLLER_USUARIO ]]; then
    ((SIMULAR)) || pedir EDA_CONTROLLER_SENHA "Senha de $EDA_CONTROLLER_USUARIO (Enter mantém a atual)"
else
    aviso "EDA_CONTROLLER_USUARIO vazio: o EDA vai lançar o job template como $AAP_USUARIO."
    EDA_CONTROLLER_USUARIO=$AAP_USUARIO
    EDA_CONTROLLER_SENHA=$AAP_SENHA
fi

# ---------------- Controller ----------------
C=/api/controller/v2
echo "Controller"
id_de org "$C/organizations/" "$AAP_ORGANIZACAO" "a organização"
id_de ee "$C/execution_environments/" "$EXECUTION_ENVIRONMENT" "o execution environment"

corpo=$(obj name="$NOME_TIPO_CREDENCIAL_SN" kind=cloud \
    description="Injeta SN_HOST e SN_INTEGRACAO_SENHA para o playbook de restart" \
    inputs:='{"fields":[{"id":"sn_host","label":"Instancia (https://...)","type":"string"},{"id":"sn_senha","label":"Senha do usuario de integracao","type":"string","secret":true}],"required":["sn_host","sn_senha"]}' \
    injectors:='{"env":{"SN_HOST":"{{ sn_host }}","SN_INTEGRACAO_SENHA":"{{ sn_senha }}"}}')
garantir tipo_sn "$C/credential_types/" "$NOME_TIPO_CREDENCIAL_SN" "$corpo" manter

cred_aws=
if [[ -n $AWS_CREDENCIAL ]]; then
    id_de cred_aws "$C/credentials/" "$AWS_CREDENCIAL" "a credencial da AWS"
    echo "  já existe:   $AWS_CREDENCIAL"
else
    echo "  sem credencial da AWS no job template (AWS_CREDENCIAL vazio)"
fi

corpo=$(obj name="$NOME_CREDENCIAL_SN" organization:="$org" credential_type:="$tipo_sn" \
    inputs:="$(obj sn_host="$SN_HOST" sn_senha="$SN_INTEGRACAO_SENHA")")
garantir_com_segredo cred_sn "$C/credentials/" "$NOME_CREDENCIAL_SN" "$SN_INTEGRACAO_SENHA" "$corpo"

campos=(name="$NOME_PROJETO" organization:="$org" scm_type=git scm_url="$REPO_GIT" scm_branch="$REPO_BRANCH"
    scm_update_on_launch:=true default_environment:="$ee")
if [[ -n $REPO_CREDENCIAL_CONTROLLER ]]; then
    id_de cred_scm "$C/credentials/" "$REPO_CREDENCIAL_CONTROLLER" "a credencial do repositório"
    campos+=(credential:="$cred_scm")
fi
garantir proj "$C/projects/" "$NOME_PROJETO" "$(obj "${campos[@]}")"
if ((SIMULAR)); then
    echo "  sincronizaria o projeto"
else
    api POST "$C/projects/$proj/update/" '{}'
    exigir "sincronizar o projeto"
    upd=$(campo "$RESP" project_update)
    [[ -n $upd ]] || upd=$(campo "$RESP" id)
    limite=$((SECONDS + 600))
    while :; do
        sleep 5
        api GET "$C/project_updates/$upd/"
        estado=$(campo "$RESP" status)
        case $estado in
            new | pending | waiting | running) ((SECONDS < limite)) || erro "a sincronização do projeto não terminou em 10 minutos" ;;
            *) break ;;
        esac
    done
    [[ $estado == successful ]] || erro "a sincronização do projeto terminou em '$estado' (project update $upd no AAP)"
    echo "  projeto sincronizado"
fi

garantir inv "$C/inventories/" "$NOME_INVENTARIO" "$(obj name="$NOME_INVENTARIO" organization:="$org")"
tem_host=
if [[ -n $inv ]]; then
    api GET "$C/inventories/$inv/hosts/?name=localhost"
    exigir "consulta aos hosts do inventário"
    tem_host=$(achar "$RESP" name localhost)
fi
if [[ -z $tem_host ]]; then
    if ((SIMULAR)); then
        echo "  criaria:     host localhost"
    else
        variaveis=$'ansible_connection: local\nansible_python_interpreter: \'{{ ansible_playbook_python }}\''
        api POST "$C/inventories/$inv/hosts/" "$(obj name=localhost variables="$variaveis")"
        exigir "criar o host localhost"
        echo "  criado:      host localhost"
    fi
fi

corpo=$(obj name="$NOME_JOB_TEMPLATE" description="Reinicia job Glue travado (acionado pelo EDA a partir da ServiceNow)" \
    project:="$proj" playbook="$PLAYBOOK" inventory:="$inv" execution_environment:="$ee" ask_variables_on_launch:=true)
garantir jt "$C/job_templates/" "$NOME_JOB_TEMPLATE" "$corpo"
if [[ -n $jt ]]; then
    api GET "$C/job_templates/$jt/credentials/"
    exigir "consulta às credenciais do job template"
    ja_tem=$RESP
    for cred in $cred_aws $cred_sn; do
        [[ -z $(achar "$ja_tem" id "$cred") ]] || continue
        if ((SIMULAR)); then
            echo "  associaria a credencial $cred ao job template"
        else
            api POST "$C/job_templates/$jt/credentials/" "$(obj id:="$cred")"
            exigir "associar a credencial $cred ao job template"
            echo "  associada:   credencial $cred ao job template"
        fi
    done
fi

# O usuário do EDA só precisa do papel Execute no job template. Se não der para conceder
# daqui (falta de permissão, usuário de outro diretório), fica o aviso e o script segue.
conceder_execute() {
    local usuario papel
    buscar "$C/users/" "$EDA_CONTROLLER_USUARIO" username
    [[ -n $OBJ ]] || return 1
    usuario=$(campo "$OBJ" id)
    buscar "$C/role_definitions/" "JobTemplate Execute"
    [[ -n $OBJ ]] || return 1
    papel=$(campo "$OBJ" id)
    api GET "$C/role_user_assignments/?user=$usuario&role_definition=$papel&object_id=$jt"
    [[ $STATUS == 2* ]] || return 1
    if [[ $(campo "$RESP" count) != 0 ]]; then
        echo "  já existe:   papel Execute de $EDA_CONTROLLER_USUARIO no job template"
    elif ((SIMULAR)); then
        echo "  concederia:  papel Execute de $EDA_CONTROLLER_USUARIO no job template"
    else
        api POST "$C/role_user_assignments/" "$(obj role_definition:="$papel" user:="$usuario" object_id="$jt")"
        [[ $STATUS == 2* ]] || return 1
        echo "  concedido:   papel Execute de $EDA_CONTROLLER_USUARIO no job template"
    fi
}
if [[ $EDA_CONTROLLER_USUARIO != "$AAP_USUARIO" && -n $jt ]]; then
    (conceder_execute) || aviso "não consegui conferir ou conceder o papel Execute de $EDA_CONTROLLER_USUARIO em '$NOME_JOB_TEMPLATE'. Confira no AAP."
fi

# ---------------- Event-Driven Ansible ----------------
E=/api/eda/v1
echo "Event-Driven Ansible"
id_de org_e "$E/organizations/" "$AAP_ORGANIZACAO" "a organização (EDA)"
id_de de "$E/decision-environments/" "$DECISION_ENVIRONMENT" "o decision environment"
id_de tipo_aap "$E/credential-types/" "Red Hat Ansible Automation Platform" "o tipo de credencial"
id_de tipo_token "$E/credential-types/" "ServiceNow Event Stream" "o tipo de credencial"

corpo=$(obj name="$NOME_CREDENCIAL_EDA_CONTROLLER" organization_id:="$org_e" credential_type_id:="$tipo_aap" \
    inputs:="$(obj host="$AAP_URL/api/controller/" username="$EDA_CONTROLLER_USUARIO" password="$EDA_CONTROLLER_SENHA" verify_ssl:=$VERIFICAR_TLS)")
garantir_com_segredo cred_aap "$E/eda-credentials/" "$NOME_CREDENCIAL_EDA_CONTROLLER" "$EDA_CONTROLLER_SENHA" "$corpo"

# Token sem "Bearer ": o EDA remove esse prefixo do cabeçalho antes de comparar
corpo=$(obj name="$NOME_CREDENCIAL_EDA_TOKEN" organization_id:="$org_e" credential_type_id:="$tipo_token" \
    inputs:="$(obj auth_type=token token="$EDA_TOKEN" http_header_key=Authorization)")
garantir_com_segredo cred_token "$E/eda-credentials/" "$NOME_CREDENCIAL_EDA_TOKEN" "$EDA_TOKEN" "$corpo"

corpo=$(obj name="$NOME_EVENT_STREAM" organization_id:="$org_e" eda_credential_id:="$cred_token" test_mode:=false)
garantir es "$E/event-streams/" "$NOME_EVENT_STREAM" "$corpo"

campos=(name="$NOME_PROJETO" organization_id:="$org_e" url="$REPO_GIT" scm_branch="$REPO_BRANCH" verify_ssl:=$VERIFICAR_TLS)
if [[ -n $REPO_CREDENCIAL_EDA ]]; then
    id_de cred_scm_e "$E/eda-credentials/" "$REPO_CREDENCIAL_EDA" "a credencial do repositório (EDA)"
    campos+=(eda_credential_id:="$cred_scm_e")
fi
garantir proj_e "$E/projects/" "$NOME_PROJETO" "$(obj "${campos[@]}")"
if ((SIMULAR)); then
    echo "  sincronizaria o projeto EDA"
else
    # sempre sincroniza, para pegar o último commit do Git
    api POST "$E/projects/$proj_e/sync/" '{}'
    [[ $STATUS == [23]* || $STATUS == 409 ]] || erro "sincronizar o projeto EDA: HTTP $STATUS ${RESP:0:400}"
    sleep 2
    limite=$((SECONDS + 300))
    while :; do
        sleep 3
        api GET "$E/projects/$proj_e/"
        estado=$(campo "$RESP" import_state)
        case $estado in
            pending | running) ((SECONDS < limite)) || erro "a importação do projeto EDA não terminou em 5 minutos" ;;
            *) break ;;
        esac
    done
    [[ $estado == completed ]] || erro "importação do projeto EDA: $estado $(campo "$RESP" import_error)"
    echo "  projeto EDA importado"
fi

rb= hash_rulebook= mapa=
if [[ -n $proj_e ]]; then
    api GET "$E/rulebooks/?project_id=$proj_e&name=$(urlenc "$RULEBOOK")&page_size=200"
    exigir "consulta aos rulebooks"
    rb=$(campo "$(achar "$RESP" name "$RULEBOOK")" id)
fi
if [[ -n $rb ]]; then
    api GET "$E/rulebooks/$rb/sources/"
    exigir "consulta às fontes do rulebook"
    hash_rulebook=$(campo "$RESP" results.0.rulebook_hash)
    mapa="- source_name: $(campo "$RESP" results.0.name)"$'\n'"  rulebook_hash: $hash_rulebook"$'\n'"  event_stream_name: $NOME_EVENT_STREAM"$'\n'"  event_stream_id: $es"$'\n'
elif ((SIMULAR)); then
    echo "  rulebook $RULEBOOK: ainda não está no projeto EDA (ou o projeto não existe)"
else
    erro "rulebook $RULEBOOK não encontrado no projeto EDA (confira a pasta rulebooks/ na branch $REPO_BRANCH)"
fi

# A activation guarda uma cópia do rulebook: se o rulebook mudou no Git, ela é recriada
buscar "$E/activations/" "$NOME_ACTIVATION"
if [[ -n $OBJ && -n $hash_rulebook && $(campo "$OBJ" source_mappings) != *"$hash_rulebook"* ]]; then
    if ((SIMULAR)); then
        echo "  recriaria:   $NOME_ACTIVATION (o rulebook mudou)"
    else
        api DELETE "$E/activations/$(campo "$OBJ" id)/"
        exigir "remover a activation antiga"
        limite=$((SECONDS + 120))
        while :; do
            sleep 3
            buscar "$E/activations/" "$NOME_ACTIVATION"
            [[ -n $OBJ ]] || break
            ((SECONDS < limite)) || erro "a activation antiga não foi removida em 2 minutos"
        done
        echo "  activation antiga removida (o rulebook mudou)"
    fi
fi

corpo=$(obj name="$NOME_ACTIVATION" description="ServiceNow (Event Stream) -> restart do job Glue" \
    organization_id:="$org_e" project_id:="$proj_e" rulebook_id:="$rb" decision_environment_id:="$de" \
    eda_credentials:="[${cred_aap:-null}]" source_mappings="$mapa" restart_policy=on-failure is_enabled:=true log_level=info)
garantir act "$E/activations/" "$NOME_ACTIVATION" "$corpo" manter
if [[ -n $act ]]; then
    limite=$((SECONDS + 300))
    while :; do
        api GET "$E/activations/$act/"
        estado=$(campo "$RESP" status)
        [[ $estado == pending || $estado == starting ]] || break
        ((!SIMULAR && SECONDS < limite)) || break
        sleep 5
    done
    echo "  activation:  $estado $(campo "$RESP" status_message)"
    [[ $estado == running ]] || aviso "a activation não está rodando. Depois de trocar credencial ou corrigir o erro, reinicie-a no AAP."
fi

echo
if [[ -n $es ]]; then
    api GET "$E/event-streams/$es/"
    exigir "consulta ao Event Stream"
    echo "Event Stream (a ServiceNow chama esta URL):"
    echo "  $(campo "$RESP" url)"
else
    echo "Event Stream: a URL aparece depois da criação."
fi
echo "O rulebook precisa citar a organização '$AAP_ORGANIZACAO' e o job template '$NOME_JOB_TEMPLATE'."
````

## para-copiar/plugins/modules/glue_job_run.py

<!-- arquivo: para-copiar/plugins/modules/glue_job_run.py | interpretador: python -->
````python
# -*- coding: utf-8 -*-
# Módulo local: as coleções amazon.aws/community.aws criam o job Glue,
# mas não iniciam, param nem consultam execuções. Usa só boto3, que já vem no EE padrão do AAP.

DOCUMENTATION = r"""
---
module: glue_job_run
short_description: Inicia, para, aguarda e consulta execuções de um job AWS Glue
description:
  - C(info) devolve a execução e os argumentos efetivos (padrões do job + argumentos da execução).
  - C(running) lista as execuções ainda ativas (STARTING, RUNNING, STOPPING, WAITING); com I(after_run_id), só as mais novas que ela.
  - C(stop) para as execuções informadas e aguarda que parem. Execução que já terminou não é erro.
  - C(start) inicia uma nova execução.
  - C(wait) aguarda uma execução terminar.
  - C(count) conta execuções numa janela de horas que tenham um argumento com certo valor.
  - C(tags) devolve as tags do job (para decidir se a automação pode agir nele).
options:
  action:
    description: O que fazer.
    type: str
    required: true
    choices: [info, running, stop, start, wait, count, tags]
  job_name:
    description: Nome do job Glue.
    type: str
    required: true
  run_id:
    description: ID da execução (para C(info) e C(wait)).
    type: str
  run_ids:
    description: IDs das execuções a parar (para C(stop)).
    type: list
    elements: str
    default: []
  arguments:
    description: Argumentos da execução (para C(start)).
    type: dict
    default: {}
  number_of_workers:
    description: Quantidade de workers (para C(start)). Exige I(worker_type).
    type: int
  worker_type:
    description: Tipo de worker, por exemplo C(G.1X) (para C(start)).
    type: str
  job_timeout:
    description: Timeout desta execução em minutos (para C(start)). Sem ele, vale o do job.
    type: int
  timeout:
    description: Segundos máximos de espera (para C(wait) e C(stop)).
    type: int
    default: 900
  argument_name:
    description: Argumento a filtrar (para C(count)).
    type: str
    default: --dt
  argument_value:
    description: Valor do argumento a contar (para C(count)).
    type: str
  hours:
    description: Janela em horas (para C(count)).
    type: int
    default: 24
  after_run_id:
    description:
      - Em C(count), só conta execuções iniciadas depois que esta execução terminou.
      - Em C(running), só lista execuções iniciadas depois do início desta execução.
    type: str
extends_documentation_fragment:
  - amazon.aws.common.modules
  - amazon.aws.region.modules
  - amazon.aws.boto3
"""

EXAMPLES = r"""
- name: Listar execuções ativas
  glue_job_run:
    action: running
    job_name: carga-diaria
  register: ativas

- name: Parar as execuções travadas
  glue_job_run:
    action: stop
    job_name: carga-diaria
    run_ids: "{{ ativas.runs | map(attribute='Id') | list }}"

- name: Reiniciar
  glue_job_run:
    action: start
    job_name: carga-diaria
    arguments: {"--origem": "ansible-restart"}
  register: novo
"""

RETURN = r"""
job_run:
  description: Dados da execução (info, wait).
  returned: when action is info or wait
  type: dict
arguments_efetivos:
  description: DefaultArguments do job sobrepostos pelos Arguments da execução.
  returned: when action is info
  type: dict
runs:
  description: Execuções ativas (running) ou paradas (stop).
  returned: when action is running or stop
  type: list
run_id:
  description: ID da execução iniciada.
  returned: when action is start
  type: str
count:
  description: Execuções encontradas na janela.
  returned: when action is count
  type: int
tags:
  description: Tags do job (vazio se o job não existir).
  returned: when action is tags
  type: dict
encontrado:
  description: Se o job existe na conta e região.
  returned: when action is tags
  type: bool
"""

import datetime
import time

try:
    import botocore
except ImportError:
    pass  # tratado pelo AnsibleAWSModule

from ansible_collections.amazon.aws.plugins.module_utils.modules import AnsibleAWSModule

ESTADOS_FINAIS = ("SUCCEEDED", "FAILED", "TIMEOUT", "STOPPED", "ERROR")
ESTADOS_ATIVOS = ("STARTING", "RUNNING", "STOPPING", "WAITING")


def serializavel(obj):
    if isinstance(obj, dict):
        return {k: serializavel(v) for k, v in obj.items()}
    if isinstance(obj, list):
        return [serializavel(v) for v in obj]
    if isinstance(obj, datetime.datetime):
        return obj.isoformat()
    return obj


def obter_execucao(glue, job_name, run_id):
    # Quando o ID vem de um campo de tamanho limitado (o correlation_id da ServiceNow tem 100
    # caracteres), ele pode chegar cortado. Nesse caso vale o prefixo, se ele for de uma execução só.
    try:
        return glue.get_job_run(JobName=job_name, RunId=run_id)["JobRun"]
    except (glue.exceptions.EntityNotFoundException, glue.exceptions.InvalidInputException):
        candidatas = [e for e in execucoes(glue, job_name) if e["Id"].startswith(run_id)]
        if len(candidatas) != 1:
            raise
        return candidatas[0]


def execucoes(glue, job_name):
    for pagina in glue.get_paginator("get_job_runs").paginate(JobName=job_name):
        yield from pagina["JobRuns"]


def aguardar(module, glue, job_name, run_id, estados, limite):
    execucao = obter_execucao(glue, job_name, run_id)
    while execucao["JobRunState"] not in estados:
        if time.time() > limite:
            module.fail_json(
                msg=f"Execução {run_id} ainda em {execucao['JobRunState']} após {module.params['timeout']}s",
                job_run=serializavel(execucao),
            )
        time.sleep(10)
        execucao = obter_execucao(glue, job_name, run_id)
    return execucao


def main():
    module = AnsibleAWSModule(
        argument_spec=dict(
            action=dict(type="str", required=True, choices=["info", "running", "stop", "start", "wait", "count", "tags"]),
            job_name=dict(type="str", required=True),
            run_id=dict(type="str"),
            run_ids=dict(type="list", elements="str", default=[]),
            arguments=dict(type="dict", default={}),
            number_of_workers=dict(type="int"),
            worker_type=dict(type="str"),
            job_timeout=dict(type="int"),
            timeout=dict(type="int", default=900),
            argument_name=dict(type="str", default="--dt"),
            argument_value=dict(type="str"),
            hours=dict(type="int", default=24),
            after_run_id=dict(type="str"),
        ),
        required_if=[
            ("action", "info", ["run_id"]),
            ("action", "wait", ["run_id"]),
            ("action", "count", ["argument_value"]),
        ],
        required_together=[("number_of_workers", "worker_type")],
        supports_check_mode=True,
    )
    p = module.params
    glue = module.client("glue")

    try:
        if p["action"] == "info":
            execucao = obter_execucao(glue, p["job_name"], p["run_id"])
            padroes = glue.get_job(JobName=p["job_name"])["Job"].get("DefaultArguments", {})
            efetivos = dict(padroes)
            efetivos.update(execucao.get("Arguments", {}))
            module.exit_json(changed=False, job_run=serializavel(execucao), arguments_efetivos=efetivos)

        if p["action"] == "running":
            ativas = [e for e in execucoes(glue, p["job_name"]) if e["JobRunState"] in ESTADOS_ATIVOS]
            if p["after_run_id"]:
                referencia = obter_execucao(glue, p["job_name"], p["after_run_id"])
                ativas = [e for e in ativas if e["Id"] != referencia["Id"] and e["StartedOn"] > referencia["StartedOn"]]
            module.exit_json(changed=False, runs=serializavel(ativas))

        if p["action"] == "stop":
            if not p["run_ids"]:
                module.exit_json(changed=False, runs=[])
            if module.check_mode:
                module.exit_json(changed=True, runs=[])
            resposta = glue.batch_stop_job_run(JobName=p["job_name"], JobRunIds=p["run_ids"])
            # Execução que terminou entre a consulta e a parada volta como erro: só falha se continuar ativa
            pendentes = [
                erro for erro in resposta.get("Errors", [])
                if obter_execucao(glue, p["job_name"], erro["JobRunId"])["JobRunState"] not in ESTADOS_FINAIS
            ]
            if pendentes:
                module.fail_json(msg="Falha ao parar execuções", errors=serializavel(pendentes))
            limite = time.time() + p["timeout"]
            paradas = [aguardar(module, glue, p["job_name"], r, ESTADOS_FINAIS, limite) for r in p["run_ids"]]
            module.exit_json(changed=True, runs=serializavel(paradas))

        if p["action"] == "start":
            if module.check_mode:
                module.exit_json(changed=True, run_id=None)
            pedido = {"JobName": p["job_name"], "Arguments": {k: str(v) for k, v in p["arguments"].items()}}
            if p["number_of_workers"]:
                pedido["NumberOfWorkers"] = p["number_of_workers"]
                pedido["WorkerType"] = p["worker_type"]
            if p["job_timeout"]:
                pedido["Timeout"] = p["job_timeout"]
            run_id = glue.start_job_run(**pedido)["JobRunId"]
            module.exit_json(changed=True, run_id=run_id)

        if p["action"] == "wait":
            execucao = aguardar(module, glue, p["job_name"], p["run_id"], ESTADOS_FINAIS, time.time() + p["timeout"])
            module.exit_json(changed=False, job_run=serializavel(execucao))

        if p["action"] == "count":
            desde = datetime.datetime.now(datetime.timezone.utc) - datetime.timedelta(hours=p["hours"])
            if p["after_run_id"]:
                referencia = obter_execucao(glue, p["job_name"], p["after_run_id"])
                desde = max(desde, referencia.get("CompletedOn") or referencia["StartedOn"])
            encontradas = [
                {"id": e["Id"], "estado": e["JobRunState"], "inicio": e["StartedOn"].isoformat()}
                for e in execucoes(glue, p["job_name"])
                if e["StartedOn"] >= desde and e.get("Arguments", {}).get(p["argument_name"]) == p["argument_value"]
            ]
            module.exit_json(changed=False, count=len(encontradas), execucoes=encontradas)

        if p["action"] == "tags":
            # O ARN do job usa a conta e a região da credencial em uso (a do papel assumido)
            identidade = module.client("sts").get_caller_identity()
            particao, conta = identidade["Arn"].split(":")[1], identidade["Account"]
            arn = f"arn:{particao}:glue:{module.region}:{conta}:job/{p['job_name']}"
            try:
                glue.get_job(JobName=p["job_name"])
            except glue.exceptions.EntityNotFoundException:
                module.exit_json(changed=False, tags={}, encontrado=False)
            module.exit_json(changed=False, tags=glue.get_tags(ResourceArn=arn).get("Tags", {}), encontrado=True)

    except (botocore.exceptions.ClientError, botocore.exceptions.BotoCoreError) as e:
        module.fail_json_aws(e, msg=f"Falha na chamada ao Glue ({p['action']})")


if __name__ == "__main__":
    main()
````

## poc.sh

<!-- arquivo: poc.sh | interpretador: bash -->
````bash
# Atalhos do POC Glue -> ServiceNow -> EDA. Rode no WSL/Linux, dentro desta pasta:
#   bash poc.sh <comando>
set -euo pipefail
cd "$(dirname "$0")"

VENV="$HOME/.venvs/poc-glue-sn"
# Lê o .env literalmente (CHAVE=valor), sem interpretar como shell: senhas com > ( ' $ funcionam
if [ -f .env ]; then
  while IFS= read -r linha || [ -n "$linha" ]; do
    linha="${linha%$'\r'}"
    case "$linha" in ''|\#*) continue ;; esac
    export "${linha%%=*}=${linha#*=}"
  done < .env
fi
[ -d "$VENV" ] && . "$VENV/bin/activate"
export ANSIBLE_LIBRARY="$PWD/library"   # o ansible.cfg é ignorado em pastas do Windows (/mnt/...)

case "${1:-}" in
  preparar)
    # .env com um token novo para o webhook
    if [ ! -f .env ]; then
      sed "s/^EDA_TOKEN=.*/EDA_TOKEN=$(python3 -c 'import secrets; print(secrets.token_hex(24))')/" .env.exemplo > .env
      chmod 600 .env
      echo ">> .env criado. Preencha SN_HOST e SN_INTEGRACAO_SENHA (a senha do admin é pedida no 'servicenow')."
    fi
    python3 -m venv "$VENV" && . "$VENV/bin/activate"
    pip install -q --upgrade pip
    pip install -q ansible-core ansible-rulebook boto3 botocore requests
    ansible-galaxy collection install -r requirements.yml
    command -v java >/dev/null || echo ">> Falta Java 17+ para o ansible-rulebook (ex.: sudo apt install openjdk-17-jre-headless)"
    command -v cloudflared >/dev/null || echo ">> Falta o cloudflared para o túnel (veja o README)"
    ;;
  servicenow)
    # A senha do admin só é usada neste comando: sem ela no .env, é pedida aqui e não fica gravada
    if [ -z "${SN_ADMIN_SENHA:-}" ]; then
      read -rs -p "Senha do admin da ServiceNow (${SN_ADMIN_USER:-admin}): " SN_ADMIN_SENHA; echo
      export SN_ADMIN_SENHA
    fi
    ansible-playbook -i inventory.yml setup/servicenow.yml
    ;;
  aws)        ansible-playbook -i inventory.yml setup/aws.yml ;;
  eda)        ansible-rulebook --rulebook rulebooks/servicenow-glue-webhook.yml -i inventory.yml --env-vars EDA_TOKEN --verbose ;;
  tunel)      cloudflared tunnel --url "http://localhost:5000" ;;
  url|url-aap)
    # url: webhook do ansible-rulebook local (raiz do túnel)
    # url-aap: Event Stream do AAP (acrescenta o caminho de event_stream_caminho.txt)
    [ -n "${2:-}" ] || { echo "uso: bash poc.sh url https://xxxx.trycloudflare.com      (ansible-rulebook local)"
                         echo "     bash poc.sh url-aap https://xxxx.trycloudflare.com  (Event Stream do AAP)"; exit 1; }
    URL="${2%/}"
    if [ "$1" = url-aap ] && [[ "$URL" != */eda-event-streams/* ]]; then
      URL="$URL$(tr -d '\r\n' < event_stream_caminho.txt)"
    fi
    EDA_WEBHOOK_URL="$URL" ansible-playbook -i inventory.yml setup/servicenow_url.yml
    ;;
  testar-eda)
    # Simula a chamada da ServiceNow direto no EDA local (incidente fictício)
    curl -sS -X POST "http://localhost:5000/" -H "Authorization: Bearer $EDA_TOKEN" -H "Content-Type: application/json" \
      -d "{\"number\": \"${2:-INC0010001}\", \"correlation_id\": \"000000000000|us-east-1|poc-glue-sn-carga-diaria|\", \"short_description\": \"[AWS Glue] Job travado: poc-glue-sn-carga-diaria\"}"
    echo
    ;;
  simular)    ansible-playbook -i inventory.yml simular_travamento.yml ;;
  destruir)   ansible-playbook -i inventory.yml setup/destruir.yml -e confirmar=sim ;;
  *)
    sed -n '2,3p' "$0"
    echo "comandos: preparar | servicenow | aws | eda | tunel | url <URL> | url-aap <URL> | testar-eda [INC] | simular | destruir"
    exit 1
    ;;
esac
````

## setup/aap_configurar.sh

<!-- arquivo: setup/aap_configurar.sh | interpretador: bash -->
````bash
# Configura no AAP, pela API, os objetos do fluxo ServiceNow -> EDA -> restart do job Glue.
# Roda em qualquer bash com curl e perl; no Windows, o Git Bash já traz os dois.
# Idempotente: pode rodar de novo.
#
#   bash setup/aap_configurar.sh [--simular] [arquivo.conf]
#
#   --simular   só consulta o AAP e mostra o que seria criado ou atualizado
#   arquivo     padrão: aap_configurar.conf, ao lado deste script (modelo: aap_configurar.conf.exemplo)
#
# O arquivo de configuração não guarda segredos. Eles são pedidos na hora, sem eco, ou vêm
# destas variáveis de ambiente:
#   AAP_SENHA             senha de AAP_USUARIO
#   AAP_TOKEN             token de API do AAP, no lugar de usuário e senha
#   SN_INTEGRACAO_SENHA   senha do usuário de integração da ServiceNow
#   EDA_TOKEN             token que a ServiceNow envia ao Event Stream
#   EDA_CONTROLLER_SENHA  senha de EDA_CONTROLLER_USUARIO
# Segredo em branco mantém a credencial que já existe no AAP.
#
# Cria: no Controller, o tipo de credencial e a credencial da ServiceNow, o projeto, o inventário
# e o job template; no EDA, as credenciais, o Event Stream, o projeto e a rulebook activation.
# Nenhum segredo vai para a linha de comando de outro programa nem para arquivo.
set -euo pipefail

erro() { printf 'ERRO: %s\n' "$*" >&2; exit 1; }
aviso() { printf 'AVISO: %s\n' "$*" >&2; }

SIMULAR=0
ARQUIVO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/aap_configurar.conf"
for arg in "$@"; do
    case $arg in
        --simular) SIMULAR=1 ;;
        -h | --help) sed -n '2,21p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) erro "opção desconhecida: $arg" ;;
        *) ARQUIVO=$arg ;;
    esac
done

command -v curl > /dev/null || erro "curl não encontrado."
perl -MJSON::PP -e 1 2> /dev/null || erro "perl com o módulo JSON::PP não encontrado (o Git Bash completo traz os dois)."

# ---------------- Configuração ----------------
CHAVES=" AAP_URL AAP_USUARIO AAP_TLS_INSEGURO AAP_ORGANIZACAO REPO_GIT REPO_BRANCH
 REPO_CREDENCIAL_CONTROLLER REPO_CREDENCIAL_EDA PLAYBOOK RULEBOOK EXECUTION_ENVIRONMENT
 DECISION_ENVIRONMENT AWS_CREDENCIAL SN_HOST EDA_CONTROLLER_USUARIO NOME_TIPO_CREDENCIAL_SN
 NOME_CREDENCIAL_SN NOME_PROJETO NOME_INVENTARIO NOME_JOB_TEMPLATE NOME_CREDENCIAL_EDA_CONTROLLER
 NOME_CREDENCIAL_EDA_TOKEN NOME_EVENT_STREAM NOME_ACTIVATION "

[[ -f $ARQUIVO ]] || erro "arquivo de configuração não encontrado: $ARQUIVO (copie o aap_configurar.conf.exemplo)"
# Lê CHAVE=valor sem executar o arquivo; o que já veio do ambiente tem prioridade
while IFS= read -r linha || [[ -n $linha ]]; do
    linha=${linha%$'\r'}
    [[ $linha =~ ^[[:space:]]*([A-Z_]+)[[:space:]]*=[[:space:]]*(.*)$ ]] || continue
    chave=${BASH_REMATCH[1]}
    valor=${BASH_REMATCH[2]}
    valor=${valor%"${valor##*[![:space:]]}"}
    [[ $CHAVES == *[[:space:]]"$chave"[[:space:]]* ]] || { aviso "chave ignorada no arquivo: $chave"; continue; }
    [[ -n ${!chave-} ]] || printf -v "$chave" '%s' "$valor"
done < "$ARQUIVO"

: "${AAP_URL:=}" "${AAP_USUARIO:=}" "${AAP_TLS_INSEGURO:=nao}" "${AAP_ORGANIZACAO:=Default}"
: "${REPO_GIT:=}" "${REPO_BRANCH:=main}" "${REPO_CREDENCIAL_CONTROLLER:=}" "${REPO_CREDENCIAL_EDA:=}"
: "${PLAYBOOK:=playbooks/restart_glue_job.yml}" "${RULEBOOK:=servicenow-glue-aap.yml}"
: "${EXECUTION_ENVIRONMENT:=}" "${DECISION_ENVIRONMENT:=}" "${AWS_CREDENCIAL:=}" "${SN_HOST:=}"
: "${EDA_CONTROLLER_USUARIO:=}"
: "${NOME_TIPO_CREDENCIAL_SN:=POC ServiceNow (integracao)}" "${NOME_CREDENCIAL_SN:=POC ServiceNow}"
: "${NOME_PROJETO:=POC Glue ServiceNow}" "${NOME_INVENTARIO:=POC localhost}"
: "${NOME_JOB_TEMPLATE:=poc-restart-glue-job}" "${NOME_CREDENCIAL_EDA_CONTROLLER:=POC AAP controller}"
: "${NOME_CREDENCIAL_EDA_TOKEN:=POC ServiceNow token}" "${NOME_EVENT_STREAM:=poc-servicenow-glue}"
: "${NOME_ACTIVATION:=poc-servicenow-glue-restart}"
: "${AAP_SENHA:=}" "${AAP_TOKEN:=}" "${SN_INTEGRACAO_SENHA:=}" "${EDA_TOKEN:=}" "${EDA_CONTROLLER_SENHA:=}"

AAP_URL=${AAP_URL%/}
for obrigatoria in AAP_URL REPO_GIT EXECUTION_ENVIRONMENT DECISION_ENVIRONMENT SN_HOST; do
    [[ -n ${!obrigatoria} ]] || erro "falta $obrigatoria em $ARQUIVO"
done
[[ $AAP_URL == https://* || $AAP_URL == http://* ]] || erro "AAP_URL precisa começar com https://"

CURL_OPCOES=(--connect-timeout 15 --max-time 90)
VERIFICAR_TLS=true
if [[ $AAP_TLS_INSEGURO == sim ]]; then
    CURL_OPCOES+=(-k)
    VERIFICAR_TLS=false
fi

# Usa a variável de ambiente; se estiver vazia e houver terminal, pergunta sem eco
pedir() {
    local valor=${!1-}
    if [[ -z $valor && -t 0 ]]; then
        read -rs -p "$2: " valor || true
        echo >&2
    fi
    printf -v "$1" '%s' "$valor"
}

if [[ -n $AAP_TOKEN ]]; then
    AUTORIZACAO="Bearer $AAP_TOKEN"
else
    [[ -n $AAP_USUARIO ]] || erro "falta AAP_USUARIO em $ARQUIVO (ou a variável de ambiente AAP_TOKEN)"
    pedir AAP_SENHA "Senha de $AAP_USUARIO no AAP"
    [[ -n $AAP_SENHA ]] || erro "senha do AAP não informada"
    AUTORIZACAO="Basic $(printf '%s' "$AAP_USUARIO:$AAP_SENHA" | base64 | tr -d '\r\n')"
fi

# ---------------- JSON (perl) e HTTP (curl) ----------------
# obj chave=texto chave:=json ...  -> objeto JSON. Os valores chegam ao perl pela entrada padrão.
obj() {
    printf '%s\0' "$@" | perl -MJSON::PP -0 -e '
        my $j = JSON::PP->new->utf8->allow_nonref; my %o;
        while (defined(my $a = <STDIN>)) {
            chomp $a;
            if ($a =~ /^([^=:]+):=(.*)$/s) { $o{$1} = length $2 ? $j->decode($2) : undef }
            elsif ($a =~ /^([^=:]+)=(.*)$/s) { my ($k, $v) = ($1, $2); utf8::decode($v); $o{$k} = $v }
            else { die "argumento invalido para obj\n" }
        }
        print JSON::PP->new->utf8->canonical->encode(\%o);'
}

# campo <json> <caminho.com.pontos>  -> valor (vazio se não existir)
campo() {
    printf '%s' "$1" | perl -MJSON::PP -0777 -e '
        my $j = JSON::PP->new->utf8->allow_nonref->canonical;
        my $d = eval { $j->decode(scalar <STDIN>) };
        for my $k (split /\./, $ARGV[0]) {
            if (ref $d eq "HASH") { $d = $d->{$k} }
            elsif (ref $d eq "ARRAY" && $k =~ /^\d+$/) { $d = $d->[$k] }
            else { exit 0 }
        }
        exit 0 unless defined $d;
        if (ref $d) { print $j->encode($d) } else { utf8::encode($d); print $d }' "$2"
}

# achar <json da lista> <campo> <valor>  -> JSON do primeiro item de "results" com campo == valor
achar() {
    printf '%s' "$1" | CAMPO=$2 VALOR=$3 perl -MJSON::PP -0777 -e '
        my $j = JSON::PP->new->utf8->canonical;
        my $d = eval { $j->decode(scalar <STDIN>) };
        exit 0 unless ref $d eq "HASH" && ref $d->{results} eq "ARRAY";
        my ($c, $v) = @ENV{qw(CAMPO VALOR)}; utf8::decode($v);
        for my $r (@{ $d->{results} }) {
            next unless ref $r eq "HASH" && defined $r->{$c} && !ref $r->{$c} && $r->{$c} eq $v;
            print $j->encode($r); last;
        }'
}

urlenc() { printf '%s' "$1" | perl -pe 's/([^A-Za-z0-9_.~-])/sprintf("%%%02X", ord($1))/ge'; }

# api <MÉTODO> <caminho> [corpo]  -> resposta em RESP, código HTTP em STATUS.
# Cabeçalho e corpo vão ao curl pela entrada padrão (-K -).
api() {
    local metodo=$1 caminho=$2 corpo=${3-} cfg saida
    cfg="url = \"$AAP_URL$caminho\""$'\n'"request = \"$metodo\""
    cfg+=$'\n'"header = \"Authorization: $AUTORIZACAO\""$'\n''header = "Accept: application/json"'
    if [[ -n $corpo ]]; then
        corpo=${corpo//\\/\\\\}
        corpo=${corpo//\"/\\\"}
        cfg+=$'\n''header = "Content-Type: application/json"'$'\n'"data-binary = \"$corpo\""
    fi
    if ! saida=$(printf '%s\n' "$cfg" | curl -sS -K - "${CURL_OPCOES[@]}" -w '\n%{http_code}'); then
        erro "sem resposta de $AAP_URL$caminho"
    fi
    STATUS=${saida##*$'\n'}
    RESP=${saida%$'\n'*}
}

exigir() { [[ $STATUS == 2* ]] || erro "$1: HTTP $STATUS ${RESP:0:400}"; }

# buscar <api> <valor> [campo]  -> JSON do objeto em OBJ (vazio se não existir)
buscar() {
    local campo_busca=${3:-name}
    api GET "$1?$campo_busca=$(urlenc "$2")"
    exigir "consulta a $1"
    OBJ=$(achar "$RESP" "$campo_busca" "$2")
}

# id_de <variável> <api> <nome> <descrição> [campo]  -> id de algo que precisa existir
id_de() {
    buscar "$2" "$3" "${5:-name}"
    [[ -n $OBJ ]] || erro "não encontrei $4 '$3' no AAP"
    printf -v "$1" '%s' "$(campo "$OBJ" id)"
}

# garantir <variável> <api> <nome> <corpo> [manter]  -> cria pelo nome ou atualiza; id na variável.
# Com "manter", o que já existe não é alterado. Na simulação, o id de algo que não existe fica vazio.
garantir() {
    local var=$1 caminho=$2 nome=$3 corpo=$4 modo=${5-} id
    buscar "$caminho" "$nome"
    if [[ -z $OBJ ]]; then
        if ((SIMULAR)); then
            echo "  criaria:     $nome"
            printf -v "$var" '%s' ''
            return 0
        fi
        api POST "$caminho" "$corpo"
        # alguns endpoints respondem à criação com redirecionamento: relê pelo nome
        [[ $STATUS == [23]* ]] || erro "criar '$nome': HTTP $STATUS ${RESP:0:400}"
        buscar "$caminho" "$nome"
        [[ -n $OBJ ]] || erro "'$nome' foi criado, mas não apareceu na consulta"
        echo "  criado:      $nome"
    elif [[ $modo == manter ]]; then
        echo "  já existe:   $nome"
    elif ((SIMULAR)); then
        echo "  atualizaria: $nome"
    else
        id=$(campo "$OBJ" id)
        api PATCH "$caminho$id/" "$corpo"
        exigir "atualizar '$nome'"
        echo "  atualizado:  $nome"
    fi
    printf -v "$var" '%s' "$(campo "$OBJ" id)"
}

# garantir_com_segredo <variável> <api> <nome> <segredo> <corpo>
# Sem o segredo, a credencial que já existe fica como está; se não existir, é erro.
garantir_com_segredo() {
    if [[ -n $4 ]]; then
        garantir "$1" "$2" "$3" "$5"
        return 0
    fi
    buscar "$2" "$3"
    if [[ -z $OBJ ]]; then
        ((SIMULAR)) || erro "'$3' ainda não existe: informe o segredo para criar"
        echo "  criaria:     $3"
    else
        echo "  mantido:     $3 (segredo não informado)"
    fi
    printf -v "$1" '%s' "$(campo "$OBJ" id)"
}

# ---------------- Acesso ----------------
if [[ -n $AAP_TOKEN && -z $EDA_CONTROLLER_USUARIO ]]; then
    erro "com AAP_TOKEN, defina EDA_CONTROLLER_USUARIO: o EDA precisa de usuário e senha para lançar o job template"
fi
((SIMULAR)) && echo "SIMULAÇÃO: só consultas; nada é criado nem alterado."
api GET "/api/gateway/v1/me/"
case $STATUS in
    2*) echo "AAP: $AAP_URL (usuário $(campo "$RESP" results.0.username))" ;;
    401 | 403) erro "o AAP recusou a autenticação (HTTP $STATUS)" ;;
    *) erro "resposta inesperada de $AAP_URL/api/gateway/v1/me/: HTTP $STATUS" ;;
esac

if ((!SIMULAR)); then
    pedir SN_INTEGRACAO_SENHA "Senha do usuário de integração da ServiceNow (Enter mantém a atual)"
    pedir EDA_TOKEN "Token que a ServiceNow envia ao Event Stream (Enter mantém o atual)"
fi
# Usuário com que o EDA lança o job template
if [[ -n $EDA_CONTROLLER_USUARIO ]]; then
    ((SIMULAR)) || pedir EDA_CONTROLLER_SENHA "Senha de $EDA_CONTROLLER_USUARIO (Enter mantém a atual)"
else
    aviso "EDA_CONTROLLER_USUARIO vazio: o EDA vai lançar o job template como $AAP_USUARIO."
    EDA_CONTROLLER_USUARIO=$AAP_USUARIO
    EDA_CONTROLLER_SENHA=$AAP_SENHA
fi

# ---------------- Controller ----------------
C=/api/controller/v2
echo "Controller"
id_de org "$C/organizations/" "$AAP_ORGANIZACAO" "a organização"
id_de ee "$C/execution_environments/" "$EXECUTION_ENVIRONMENT" "o execution environment"

corpo=$(obj name="$NOME_TIPO_CREDENCIAL_SN" kind=cloud \
    description="Injeta SN_HOST e SN_INTEGRACAO_SENHA para o playbook de restart" \
    inputs:='{"fields":[{"id":"sn_host","label":"Instancia (https://...)","type":"string"},{"id":"sn_senha","label":"Senha do usuario de integracao","type":"string","secret":true}],"required":["sn_host","sn_senha"]}' \
    injectors:='{"env":{"SN_HOST":"{{ sn_host }}","SN_INTEGRACAO_SENHA":"{{ sn_senha }}"}}')
garantir tipo_sn "$C/credential_types/" "$NOME_TIPO_CREDENCIAL_SN" "$corpo" manter

cred_aws=
if [[ -n $AWS_CREDENCIAL ]]; then
    id_de cred_aws "$C/credentials/" "$AWS_CREDENCIAL" "a credencial da AWS"
    echo "  já existe:   $AWS_CREDENCIAL"
else
    echo "  sem credencial da AWS no job template (AWS_CREDENCIAL vazio)"
fi

corpo=$(obj name="$NOME_CREDENCIAL_SN" organization:="$org" credential_type:="$tipo_sn" \
    inputs:="$(obj sn_host="$SN_HOST" sn_senha="$SN_INTEGRACAO_SENHA")")
garantir_com_segredo cred_sn "$C/credentials/" "$NOME_CREDENCIAL_SN" "$SN_INTEGRACAO_SENHA" "$corpo"

campos=(name="$NOME_PROJETO" organization:="$org" scm_type=git scm_url="$REPO_GIT" scm_branch="$REPO_BRANCH"
    scm_update_on_launch:=true default_environment:="$ee")
if [[ -n $REPO_CREDENCIAL_CONTROLLER ]]; then
    id_de cred_scm "$C/credentials/" "$REPO_CREDENCIAL_CONTROLLER" "a credencial do repositório"
    campos+=(credential:="$cred_scm")
fi
garantir proj "$C/projects/" "$NOME_PROJETO" "$(obj "${campos[@]}")"
if ((SIMULAR)); then
    echo "  sincronizaria o projeto"
else
    api POST "$C/projects/$proj/update/" '{}'
    exigir "sincronizar o projeto"
    upd=$(campo "$RESP" project_update)
    [[ -n $upd ]] || upd=$(campo "$RESP" id)
    limite=$((SECONDS + 600))
    while :; do
        sleep 5
        api GET "$C/project_updates/$upd/"
        estado=$(campo "$RESP" status)
        case $estado in
            new | pending | waiting | running) ((SECONDS < limite)) || erro "a sincronização do projeto não terminou em 10 minutos" ;;
            *) break ;;
        esac
    done
    [[ $estado == successful ]] || erro "a sincronização do projeto terminou em '$estado' (project update $upd no AAP)"
    echo "  projeto sincronizado"
fi

garantir inv "$C/inventories/" "$NOME_INVENTARIO" "$(obj name="$NOME_INVENTARIO" organization:="$org")"
tem_host=
if [[ -n $inv ]]; then
    api GET "$C/inventories/$inv/hosts/?name=localhost"
    exigir "consulta aos hosts do inventário"
    tem_host=$(achar "$RESP" name localhost)
fi
if [[ -z $tem_host ]]; then
    if ((SIMULAR)); then
        echo "  criaria:     host localhost"
    else
        variaveis=$'ansible_connection: local\nansible_python_interpreter: \'{{ ansible_playbook_python }}\''
        api POST "$C/inventories/$inv/hosts/" "$(obj name=localhost variables="$variaveis")"
        exigir "criar o host localhost"
        echo "  criado:      host localhost"
    fi
fi

corpo=$(obj name="$NOME_JOB_TEMPLATE" description="Reinicia job Glue travado (acionado pelo EDA a partir da ServiceNow)" \
    project:="$proj" playbook="$PLAYBOOK" inventory:="$inv" execution_environment:="$ee" ask_variables_on_launch:=true)
garantir jt "$C/job_templates/" "$NOME_JOB_TEMPLATE" "$corpo"
if [[ -n $jt ]]; then
    api GET "$C/job_templates/$jt/credentials/"
    exigir "consulta às credenciais do job template"
    ja_tem=$RESP
    for cred in $cred_aws $cred_sn; do
        [[ -z $(achar "$ja_tem" id "$cred") ]] || continue
        if ((SIMULAR)); then
            echo "  associaria a credencial $cred ao job template"
        else
            api POST "$C/job_templates/$jt/credentials/" "$(obj id:="$cred")"
            exigir "associar a credencial $cred ao job template"
            echo "  associada:   credencial $cred ao job template"
        fi
    done
fi

# O usuário do EDA só precisa do papel Execute no job template. Se não der para conceder
# daqui (falta de permissão, usuário de outro diretório), fica o aviso e o script segue.
conceder_execute() {
    local usuario papel
    buscar "$C/users/" "$EDA_CONTROLLER_USUARIO" username
    [[ -n $OBJ ]] || return 1
    usuario=$(campo "$OBJ" id)
    buscar "$C/role_definitions/" "JobTemplate Execute"
    [[ -n $OBJ ]] || return 1
    papel=$(campo "$OBJ" id)
    api GET "$C/role_user_assignments/?user=$usuario&role_definition=$papel&object_id=$jt"
    [[ $STATUS == 2* ]] || return 1
    if [[ $(campo "$RESP" count) != 0 ]]; then
        echo "  já existe:   papel Execute de $EDA_CONTROLLER_USUARIO no job template"
    elif ((SIMULAR)); then
        echo "  concederia:  papel Execute de $EDA_CONTROLLER_USUARIO no job template"
    else
        api POST "$C/role_user_assignments/" "$(obj role_definition:="$papel" user:="$usuario" object_id="$jt")"
        [[ $STATUS == 2* ]] || return 1
        echo "  concedido:   papel Execute de $EDA_CONTROLLER_USUARIO no job template"
    fi
}
if [[ $EDA_CONTROLLER_USUARIO != "$AAP_USUARIO" && -n $jt ]]; then
    (conceder_execute) || aviso "não consegui conferir ou conceder o papel Execute de $EDA_CONTROLLER_USUARIO em '$NOME_JOB_TEMPLATE'. Confira no AAP."
fi

# ---------------- Event-Driven Ansible ----------------
E=/api/eda/v1
echo "Event-Driven Ansible"
id_de org_e "$E/organizations/" "$AAP_ORGANIZACAO" "a organização (EDA)"
id_de de "$E/decision-environments/" "$DECISION_ENVIRONMENT" "o decision environment"
id_de tipo_aap "$E/credential-types/" "Red Hat Ansible Automation Platform" "o tipo de credencial"
id_de tipo_token "$E/credential-types/" "ServiceNow Event Stream" "o tipo de credencial"

corpo=$(obj name="$NOME_CREDENCIAL_EDA_CONTROLLER" organization_id:="$org_e" credential_type_id:="$tipo_aap" \
    inputs:="$(obj host="$AAP_URL/api/controller/" username="$EDA_CONTROLLER_USUARIO" password="$EDA_CONTROLLER_SENHA" verify_ssl:=$VERIFICAR_TLS)")
garantir_com_segredo cred_aap "$E/eda-credentials/" "$NOME_CREDENCIAL_EDA_CONTROLLER" "$EDA_CONTROLLER_SENHA" "$corpo"

# Token sem "Bearer ": o EDA remove esse prefixo do cabeçalho antes de comparar
corpo=$(obj name="$NOME_CREDENCIAL_EDA_TOKEN" organization_id:="$org_e" credential_type_id:="$tipo_token" \
    inputs:="$(obj auth_type=token token="$EDA_TOKEN" http_header_key=Authorization)")
garantir_com_segredo cred_token "$E/eda-credentials/" "$NOME_CREDENCIAL_EDA_TOKEN" "$EDA_TOKEN" "$corpo"

corpo=$(obj name="$NOME_EVENT_STREAM" organization_id:="$org_e" eda_credential_id:="$cred_token" test_mode:=false)
garantir es "$E/event-streams/" "$NOME_EVENT_STREAM" "$corpo"

campos=(name="$NOME_PROJETO" organization_id:="$org_e" url="$REPO_GIT" scm_branch="$REPO_BRANCH" verify_ssl:=$VERIFICAR_TLS)
if [[ -n $REPO_CREDENCIAL_EDA ]]; then
    id_de cred_scm_e "$E/eda-credentials/" "$REPO_CREDENCIAL_EDA" "a credencial do repositório (EDA)"
    campos+=(eda_credential_id:="$cred_scm_e")
fi
garantir proj_e "$E/projects/" "$NOME_PROJETO" "$(obj "${campos[@]}")"
if ((SIMULAR)); then
    echo "  sincronizaria o projeto EDA"
else
    # sempre sincroniza, para pegar o último commit do Git
    api POST "$E/projects/$proj_e/sync/" '{}'
    [[ $STATUS == [23]* || $STATUS == 409 ]] || erro "sincronizar o projeto EDA: HTTP $STATUS ${RESP:0:400}"
    sleep 2
    limite=$((SECONDS + 300))
    while :; do
        sleep 3
        api GET "$E/projects/$proj_e/"
        estado=$(campo "$RESP" import_state)
        case $estado in
            pending | running) ((SECONDS < limite)) || erro "a importação do projeto EDA não terminou em 5 minutos" ;;
            *) break ;;
        esac
    done
    [[ $estado == completed ]] || erro "importação do projeto EDA: $estado $(campo "$RESP" import_error)"
    echo "  projeto EDA importado"
fi

rb= hash_rulebook= mapa=
if [[ -n $proj_e ]]; then
    api GET "$E/rulebooks/?project_id=$proj_e&name=$(urlenc "$RULEBOOK")&page_size=200"
    exigir "consulta aos rulebooks"
    rb=$(campo "$(achar "$RESP" name "$RULEBOOK")" id)
fi
if [[ -n $rb ]]; then
    api GET "$E/rulebooks/$rb/sources/"
    exigir "consulta às fontes do rulebook"
    hash_rulebook=$(campo "$RESP" results.0.rulebook_hash)
    mapa="- source_name: $(campo "$RESP" results.0.name)"$'\n'"  rulebook_hash: $hash_rulebook"$'\n'"  event_stream_name: $NOME_EVENT_STREAM"$'\n'"  event_stream_id: $es"$'\n'
elif ((SIMULAR)); then
    echo "  rulebook $RULEBOOK: ainda não está no projeto EDA (ou o projeto não existe)"
else
    erro "rulebook $RULEBOOK não encontrado no projeto EDA (confira a pasta rulebooks/ na branch $REPO_BRANCH)"
fi

# A activation guarda uma cópia do rulebook: se o rulebook mudou no Git, ela é recriada
buscar "$E/activations/" "$NOME_ACTIVATION"
if [[ -n $OBJ && -n $hash_rulebook && $(campo "$OBJ" source_mappings) != *"$hash_rulebook"* ]]; then
    if ((SIMULAR)); then
        echo "  recriaria:   $NOME_ACTIVATION (o rulebook mudou)"
    else
        api DELETE "$E/activations/$(campo "$OBJ" id)/"
        exigir "remover a activation antiga"
        limite=$((SECONDS + 120))
        while :; do
            sleep 3
            buscar "$E/activations/" "$NOME_ACTIVATION"
            [[ -n $OBJ ]] || break
            ((SECONDS < limite)) || erro "a activation antiga não foi removida em 2 minutos"
        done
        echo "  activation antiga removida (o rulebook mudou)"
    fi
fi

corpo=$(obj name="$NOME_ACTIVATION" description="ServiceNow (Event Stream) -> restart do job Glue" \
    organization_id:="$org_e" project_id:="$proj_e" rulebook_id:="$rb" decision_environment_id:="$de" \
    eda_credentials:="[${cred_aap:-null}]" source_mappings="$mapa" restart_policy=on-failure is_enabled:=true log_level=info)
garantir act "$E/activations/" "$NOME_ACTIVATION" "$corpo" manter
if [[ -n $act ]]; then
    limite=$((SECONDS + 300))
    while :; do
        api GET "$E/activations/$act/"
        estado=$(campo "$RESP" status)
        [[ $estado == pending || $estado == starting ]] || break
        ((!SIMULAR && SECONDS < limite)) || break
        sleep 5
    done
    echo "  activation:  $estado $(campo "$RESP" status_message)"
    [[ $estado == running ]] || aviso "a activation não está rodando. Depois de trocar credencial ou corrigir o erro, reinicie-a no AAP."
fi

echo
if [[ -n $es ]]; then
    api GET "$E/event-streams/$es/"
    exigir "consulta ao Event Stream"
    echo "Event Stream (a ServiceNow chama esta URL):"
    echo "  $(campo "$RESP" url)"
else
    echo "Event Stream: a URL aparece depois da criação."
fi
echo "O rulebook precisa citar a organização '$AAP_ORGANIZACAO' e o job template '$NOME_JOB_TEMPLATE'."
````
