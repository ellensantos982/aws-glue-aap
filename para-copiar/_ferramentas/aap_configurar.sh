#!/usr/bin/env bash
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
