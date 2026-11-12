#!/usr/bin/env bash
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
