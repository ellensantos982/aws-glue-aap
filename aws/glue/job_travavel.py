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
