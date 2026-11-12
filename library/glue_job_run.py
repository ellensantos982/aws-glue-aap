#!/usr/bin/python
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
