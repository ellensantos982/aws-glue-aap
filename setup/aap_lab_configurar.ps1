<#
  Configura o POC Glue -> ServiceNow -> EDA no AAP do lab (aap.lab.example) pela API.
  Idempotente: pode rodar de novo. Lê os segredos dos arquivos locais, sem exibi-los:
    - admin do AAP ......... C:\poc\aap-lab\segredos\aap.env
    - ServiceNow e token ... C:\poc\poc-glue-servicenow\.env
    - AWS .................. perfil [poc-aap] do ~/.aws/credentials do WSL: a chave do usuário
                             poc-glue-sn-aap, criado pela stack, que só assume o papel de automação

      pwsh -File C:\poc\poc-glue-servicenow\setup\aap_lab_configurar.ps1

  Cria: no Controller, tipo de credencial e credenciais (AWS, ServiceNow), projeto, inventário
  e o job template "poc-restart-glue-job"; no EDA, credenciais, o Event Stream que a ServiceNow
  chama, o projeto e a rulebook activation.

  O EDA lança o job template com um usuário próprio (poc-eda), que só tem o papel Execute nesse
  template. A senha dele é gerada na primeira vez e guardada em aap.env. Para usar o admin de
  propósito (por exemplo, se a criação desse usuário falhar), rode com -EdaComAdmin.
#>
param(
    [string]$Base = "https://aap.lab.example",
    # Git smart HTTP na VM (o EDA clona com --depth, que o HTTP "dumb" não suporta)
    [string]$RepoGit = "http://<ip-da-vm>:8090/cgi-bin/git/poc-glue-servicenow.git",
    [string]$ArquivoAap = "C:\poc\aap-lab\segredos\aap.env",
    [string]$ArquivoPoc = "C:\poc\poc-glue-servicenow\.env",
    [string]$ArquivoAws = "\\wsl.localhost\Ubuntu\home\<usuario>\.aws\credentials",
    [string]$PerfilAws = "poc-aap",
    [string]$UsuarioEda = "poc-eda",
    [switch]$EdaComAdmin
)
$ErrorActionPreference = "Stop"

function Ler-Env($caminho) {
    $r = @{}
    Get-Content $caminho | Where-Object { $_ -match '^[A-Z_]+=' } | ForEach-Object { $n, $v = $_ -split '=', 2; $r[$n] = $v }
    $r
}
function Ler-Aws($caminho, $perfil) {
    $r = @{}; $noPerfil = $false
    foreach ($l in Get-Content $caminho) {
        if ($l -match '^\s*\[(.+)\]') { $noPerfil = ($Matches[1] -eq $perfil); continue }
        if ($noPerfil -and $l -match '^\s*([a-z_]+)\s*=\s*(.+?)\s*$') { $r[$Matches[1]] = $Matches[2] }
    }
    $r
}

$aap = Ler-Env $ArquivoAap
$poc = Ler-Env $ArquivoPoc
$aws = Ler-Aws $ArquivoAws $PerfilAws
foreach ($obrigatorio in @($aap.AAP_ADMIN_SENHA, $poc.SN_HOST, $poc.SN_INTEGRACAO_SENHA, $poc.EDA_TOKEN)) {
    if (-not $obrigatorio) { throw "Falta algum segredo (aap.env ou .env do POC)." }
}
# A credencial que fica no AAP é a do usuário mínimo, não a que cria a stack
if (-not $aws.aws_access_key_id -or -not $aws.aws_secret_access_key) {
    throw @"
Perfil [$PerfilAws] não encontrado em $ArquivoAws.
Ele guarda a chave do usuário poc-glue-sn-aap (criado pela stack; só assume o papel de automação).
No WSL, com o perfil que administra a conta:
  aws iam create-access-key --user-name poc-glue-sn-aap --profile poc
e grave o resultado em ~/.aws/credentials, na seção [$PerfilAws].
"@
}
$H = @{ Authorization = "Basic " + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("$($aap.AAP_ADMIN_USUARIO):$($aap.AAP_ADMIN_SENHA)")) }

function Api($metodo, $caminho, $corpo) {
    $p = @{ Method = $metodo; Uri = "$Base$caminho"; Headers = $H; SkipCertificateCheck = $true; TimeoutSec = 60 }
    if ($null -ne $corpo) { $p.Body = ($corpo | ConvertTo-Json -Depth 10 -Compress); $p.ContentType = "application/json" }
    Invoke-RestMethod @p
}
function Buscar($api, $nome) {
    (Api GET "$api`?name=$([uri]::EscapeDataString($nome))").results | Where-Object name -eq $nome | Select-Object -First 1
}
# Cria pelo nome ou atualiza o que já existe; devolve o objeto
function Garantir($api, $nome, $corpo, [switch]$SemAtualizar) {
    $existe = Buscar $api $nome
    if (-not $existe) {
        # relê pelo nome: a resposta de criação de alguns endpoints vem como redirecionamento
        try { Api POST $api $corpo | Out-Null } catch { if ($_.Exception.Message -notmatch "redirecionamento|redirect") { throw } }
        Write-Host "  criado:     $nome"; return (Buscar $api $nome)
    }
    if ($SemAtualizar) { Write-Host "  já existe:  $nome"; return $existe }
    $o = Api PATCH "$api$($existe.id)/" $corpo; Write-Host "  atualizado: $nome"; return $o
}

# ---------------- Controller ----------------
$C = "/api/controller/v2"
Write-Host "Controller"
$org = (Buscar "$C/organizations/" "Default").id
$ee = (Buscar "$C/execution_environments/" "Hub Default execution environment").id

$tipoSn = Garantir "$C/credential_types/" "POC ServiceNow (integracao)" @{
    name        = "POC ServiceNow (integracao)"
    kind        = "cloud"
    description = "Injeta SN_HOST e SN_INTEGRACAO_SENHA para o restart_glue_job.yml"
    inputs      = @{
        fields   = @(
            @{ id = "sn_host"; label = "Instancia (https://...)"; type = "string" },
            @{ id = "sn_senha"; label = "Senha de poc.integracao.aws"; type = "string"; secret = $true }
        )
        required = @("sn_host", "sn_senha")
    }
    injectors   = @{ env = @{ SN_HOST = "{{ sn_host }}"; SN_INTEGRACAO_SENHA = "{{ sn_senha }}" } }
} -SemAtualizar

$credAws = Garantir "$C/credentials/" "POC AWS" @{
    name = "POC AWS"; organization = $org; credential_type = (Buscar "$C/credential_types/" "Amazon Web Services").id
    inputs = @{ username = $aws.aws_access_key_id; password = $aws.aws_secret_access_key }
}
$credSn = Garantir "$C/credentials/" "POC ServiceNow" @{
    name = "POC ServiceNow"; organization = $org; credential_type = $tipoSn.id
    inputs = @{ sn_host = $poc.SN_HOST; sn_senha = $poc.SN_INTEGRACAO_SENHA }
}

$proj = Garantir "$C/projects/" "POC Glue ServiceNow" @{
    name = "POC Glue ServiceNow"; organization = $org; scm_type = "git"; scm_url = $RepoGit; scm_branch = "main"
    scm_update_on_launch = $true; default_environment = $ee
}
$upd = Api POST "$C/projects/$($proj.id)/update/" @{}
$idUpd = if ($upd.project_update) { $upd.project_update } else { $upd.id }
do { Start-Sleep -Seconds 5; $st = (Api GET "$C/project_updates/$idUpd/").status } while ($st -in "new", "pending", "waiting", "running")
if ($st -ne "successful") { throw "Sincronização do projeto terminou em '$st' (job $idUpd no AAP)." }
Write-Host "  projeto sincronizado"

$inv = Garantir "$C/inventories/" "POC localhost" @{ name = "POC localhost"; organization = $org }
if (-not (Api GET "$C/inventories/$($inv.id)/hosts/?name=localhost").results) {
    Api POST "$C/inventories/$($inv.id)/hosts/" @{ name = "localhost"; variables = "ansible_connection: local`nansible_python_interpreter: '{{ ansible_playbook_python }}'" } | Out-Null
    Write-Host "  criado:     host localhost"
}

$jt = Garantir "$C/job_templates/" "poc-restart-glue-job" @{
    name = "poc-restart-glue-job"; description = "Reinicia job Glue travado (acionado pelo EDA a partir da ServiceNow)"
    project = $proj.id; playbook = "restart_glue_job.yml"; inventory = $inv.id; execution_environment = $ee
    ask_variables_on_launch = $true
}
$jaTem = (Api GET "$C/job_templates/$($jt.id)/credentials/").results.id
foreach ($cred in $credAws, $credSn) {
    if ($jaTem -notcontains $cred.id) { Api POST "$C/job_templates/$($jt.id)/credentials/" @{ id = $cred.id } | Out-Null }
}

# ---------------- Usuário do EDA no Controller ----------------
# O EDA só precisa lançar um job template: em vez do admin, usa um usuário com Execute nesse template.
$loginEda = @{ usuario = $aap.AAP_ADMIN_USUARIO; senha = $aap.AAP_ADMIN_SENHA }
if ($EdaComAdmin) {
    Write-Warning "EDA configurado com o usuário admin (-EdaComAdmin)."
} else {
    try {
        $senhaNova = -not $aap.AAP_EDA_SENHA
        if ($senhaNova) {
            $aap.AAP_EDA_SENHA = [Convert]::ToHexString([Security.Cryptography.RandomNumberGenerator]::GetBytes(24))
        }
        $G = "/api/gateway/v1"
        $filtro = "?username=$([uri]::EscapeDataString($UsuarioEda))"
        $usuario = (Api GET "$G/users/$filtro").results | Where-Object username -eq $UsuarioEda | Select-Object -First 1
        if (-not $usuario) {
            Api POST "$G/users/" @{ username = $UsuarioEda; password = $aap.AAP_EDA_SENHA; first_name = "POC"; last_name = "EDA" } | Out-Null
            Write-Host "  criado:     usuário $UsuarioEda"
        } elseif ($senhaNova) {
            # o usuário existe, mas a senha não está mais em aap.env: define uma nova
            Api PATCH "$G/users/$($usuario.id)/" @{ password = $aap.AAP_EDA_SENHA } | Out-Null
            Write-Host "  atualizado: senha do usuário $UsuarioEda"
        }
        if ($senhaNova) {
            # só grava depois que o AAP aceitou a senha
            $texto = Get-Content $ArquivoAap -Raw
            $linhas = "AAP_EDA_USUARIO=$UsuarioEda`nAAP_EDA_SENHA=$($aap.AAP_EDA_SENHA)`n"
            Add-Content -Path $ArquivoAap -NoNewline -Value ($(if ($texto -and -not $texto.EndsWith("`n")) { "`n" }) + $linhas)
        }
        # o usuário é criado no gateway e leva alguns segundos para aparecer no Controller
        $limite = (Get-Date).AddMinutes(1)
        do {
            $noController = (Api GET "$C/users/$filtro").results | Where-Object username -eq $UsuarioEda | Select-Object -First 1
            if (-not $noController) { Start-Sleep -Seconds 3 }
        } while (-not $noController -and (Get-Date) -lt $limite)
        if (-not $noController) { throw "o usuário não apareceu no Controller em 1 minuto" }

        $papel = Buscar "$C/role_definitions/" "JobTemplate Execute"
        if (-not $papel) { throw "papel 'JobTemplate Execute' não encontrado no Controller" }
        $jaTemPapel = (Api GET "$C/role_user_assignments/?user=$($noController.id)&role_definition=$($papel.id)&object_id=$($jt.id)").results
        if (-not $jaTemPapel) {
            Api POST "$C/role_user_assignments/" @{ role_definition = $papel.id; user = $noController.id; object_id = "$($jt.id)" } | Out-Null
            Write-Host "  criado:     papel Execute de $UsuarioEda em $($jt.name)"
        }
        $loginEda = @{ usuario = $UsuarioEda; senha = $aap.AAP_EDA_SENHA }
    } catch {
        throw "Não foi possível preparar o usuário '$UsuarioEda' para o EDA: $($_.Exception.Message) Para usar o admin de propósito, rode com -EdaComAdmin."
    }
}

# ---------------- Event-Driven Ansible ----------------
$E = "/api/eda/v1"
Write-Host "Event-Driven Ansible"
$orgE = (Buscar "$E/organizations/" "Default").id
$de = (Buscar "$E/decision-environments/" "Hub Default Decision Environment").id

$credAap = Garantir "$E/eda-credentials/" "POC AAP controller" @{
    name = "POC AAP controller"; organization_id = $orgE
    credential_type_id = (Buscar "$E/credential-types/" "Red Hat Ansible Automation Platform").id
    inputs = @{ host = "$Base/api/controller/"; username = $loginEda.usuario; password = $loginEda.senha; verify_ssl = $false }
}
# Token sem "Bearer ": o EDA remove esse prefixo do cabeçalho antes de comparar
$credTok = Garantir "$E/eda-credentials/" "POC ServiceNow token" @{
    name = "POC ServiceNow token"; organization_id = $orgE
    credential_type_id = (Buscar "$E/credential-types/" "ServiceNow Event Stream").id
    inputs = @{ auth_type = "token"; token = $poc.EDA_TOKEN; http_header_key = "Authorization" }
}
$es = Garantir "$E/event-streams/" "poc-servicenow-glue" @{
    name = "poc-servicenow-glue"; organization_id = $orgE; eda_credential_id = $credTok.id; test_mode = $false
}

$projE = Garantir "$E/projects/" "POC Glue ServiceNow" @{
    name = "POC Glue ServiceNow"; organization_id = $orgE; url = $RepoGit; scm_branch = "main"; verify_ssl = $false
}
# sempre sincroniza, para pegar o último commit do Git
try { Api POST "$E/projects/$($projE.id)/sync/" @{} | Out-Null } catch { if ($_.Exception.Message -notmatch "redirecionamento|redirect") { throw } }
Start-Sleep -Seconds 2
do { Start-Sleep -Seconds 3; $pe = Api GET "$E/projects/$($projE.id)/" } while ($pe.import_state -in "pending", "running")
if ($pe.import_state -ne "completed") { throw "Importação do projeto EDA: $($pe.import_state) $($pe.import_error)" }
Write-Host "  projeto EDA importado"

$rb = (Api GET "$E/rulebooks/?project_id=$($projE.id)").results | Where-Object name -eq "servicenow-glue-aap.yml" | Select-Object -First 1
if (-not $rb) { throw "Rulebook servicenow-glue-aap.yml não encontrado no projeto EDA." }
$fonte = (Api GET "$E/rulebooks/$($rb.id)/sources/").results | Select-Object -First 1
$mapa = "- source_name: $($fonte.name)`n  rulebook_hash: $($fonte.rulebook_hash)`n  event_stream_name: $($es.name)`n  event_stream_id: $($es.id)`n"

# A activation guarda uma cópia do rulebook: se o rulebook mudou no Git, recria a activation.
# A comparação é pelo hash do rulebook, que fica no mapa de fontes da activation.
$atual = Buscar "$E/activations/" "poc-servicenow-glue-restart"
if ($atual -and "$($atual.source_mappings)" -notlike "*$($fonte.rulebook_hash)*") {
    Api DELETE "$E/activations/$($atual.id)/" $null | Out-Null
    $limite = (Get-Date).AddMinutes(2)
    while ((Buscar "$E/activations/" "poc-servicenow-glue-restart") -and (Get-Date) -lt $limite) { Start-Sleep -Seconds 3 }
    Write-Host "  activation antiga removida (rulebook mudou)"
}

$act = Garantir "$E/activations/" "poc-servicenow-glue-restart" @{
    name = "poc-servicenow-glue-restart"; description = "ServiceNow (Event Stream) -> restart do job Glue"
    organization_id = $orgE; project_id = $projE.id; rulebook_id = $rb.id; decision_environment_id = $de
    eda_credentials = @($credAap.id); source_mappings = $mapa
    restart_policy = "on-failure"; is_enabled = $true; log_level = "info"
} -SemAtualizar
$limite = (Get-Date).AddMinutes(5)
do { Start-Sleep -Seconds 5; $a = Api GET "$E/activations/$($act.id)/" } while ($a.status -in "pending", "starting" -and (Get-Date) -lt $limite)
Write-Host "  activation: $($a.status) $($a.status_message)"

$url = (Api GET "$E/event-streams/$($es.id)/").url
Write-Host ""
Write-Host "Event Stream (a ServiceNow chama este caminho):"
Write-Host "  $url"
$caminho = ([uri]$url).AbsolutePath
Write-Host "Caminho para usar com o túnel: $caminho"
Set-Content -Path (Join-Path $PSScriptRoot "..\event_stream_caminho.txt") -Value $caminho -Encoding utf8
