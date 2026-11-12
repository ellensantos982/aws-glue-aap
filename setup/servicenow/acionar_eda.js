// Business rule (async, after insert, tabela incident).
// Condição: correlation_display == 'aws-glue' e incidente criado pelo usuário de integração
// (definida em setup/servicenow.yml) -> só incidentes abertos pelo EventBridge.
// Chama o webhook do Event-Driven Ansible e anota o resultado no incidente.
(function executeRule(current, previous /* null em regras async */) {
    function anotar(campos) {
        var inc = new GlideRecord('incident');
        if (inc.get(current.getUniqueValue())) {
            for (var campo in campos) {
                if (campo == 'work_notes') {
                    // campo de diário: o setValue não cria a entrada; a atribuição direta cria
                    inc.work_notes = campos[campo];
                } else {
                    inc.setValue(campo, campos[campo]);
                }
            }
            inc.update();
        }
    }

    var correlacao = current.getValue('correlation_id');
    if (!correlacao) {
        anotar({ work_notes: 'Incidente sem correlation_id: o Event-Driven Ansible não foi acionado.' });
        return;
    }

    // Deduplicação: o EventBridge reenvia o evento se a ServiceNow demorar a responder (limite de 5 s),
    // o que abre um segundo incidente para a mesma execução. Fecha o repetido e não chama o EDA.
    // Só é repetido quem foi criado DEPOIS de outro incidente igual: assim, mesmo que as regras dos
    // dois rodem ao mesmo tempo, o mais antigo sempre segue para o EDA e só o mais novo é fechado.
    // sys_created_on tem precisão de segundos; no empate, o original é o de menor número.
    function veioAntes(outro) {
        var criadoOutro = outro.getValue('sys_created_on');
        var criadoAtual = current.getValue('sys_created_on');
        if (criadoOutro != criadoAtual) {
            return criadoOutro < criadoAtual;
        }
        var numOutro = outro.getValue('number');
        var numAtual = current.getValue('number');
        if (numOutro.length != numAtual.length) {
            return numOutro.length < numAtual.length;
        }
        return numOutro < numAtual;
    }

    var outro = new GlideRecord('incident');
    outro.addQuery('correlation_display', 'aws-glue');
    outro.addQuery('correlation_id', correlacao);
    outro.addQuery('sys_id', '!=', current.getUniqueValue());
    outro.orderBy('sys_created_on');
    outro.orderBy('number');
    outro.query();
    while (outro.next()) {
        if (veioAntes(outro)) {
            var numero = outro.getValue('number');
            anotar({
                parent_incident: outro.getUniqueValue(),
                state: 6, // Resolved
                close_code: 'Duplicate',
                close_notes: 'Duplicado de ' + numero +
                    ' (mesmo job e mesma execução do Glue). O Event-Driven Ansible não foi acionado de novo.',
                work_notes: 'Duplicado de ' + numero + '; Event-Driven Ansible não acionado.'
            });
            return;
        }
    }

    var corpo = {
        number: current.getValue('number'),
        sys_id: current.getUniqueValue(),
        correlation_id: correlacao,
        short_description: current.getValue('short_description')
    };

    // Uma tentativa; devolve se deu certo, a nota e se vale repetir.
    // Falha de rede, timeout e erro 5xx costumam ser passageiros (túnel ou AAP reiniciando).
    // Erro 4xx (token ou URL errados) não melhora repetindo.
    function chamarEda() {
        try {
            var r = new sn_ws.RESTMessageV2();
            r.setEndpoint(gs.getProperty('poc.eda.webhook_url'));
            r.setHttpMethod('post');
            r.setRequestHeader('Content-Type', 'application/json');
            r.setRequestHeader('Authorization', 'Bearer ' + gs.getProperty('poc.eda.token'));
            r.setRequestBody(JSON.stringify(corpo));
            r.setHttpTimeout(15000);
            var resposta = r.execute();
            var status = resposta.getStatusCode();
            if (status >= 200 && status < 300) {
                return { ok: true, nota: 'Event-Driven Ansible acionado (HTTP ' + status + ')' };
            }
            return {
                ok: false,
                nota: 'Falha ao acionar o Event-Driven Ansible (HTTP ' + status + '): ' + resposta.getErrorMessage(),
                repetir: status == 0 || status >= 500
            };
        } catch (e) {
            return { ok: false, nota: 'Falha ao acionar o Event-Driven Ansible: ' + e.message, repetir: true };
        }
    }

    // Se a primeira entrega chegou mas a resposta se perdeu, a repetição não reinicia o job duas
    // vezes: o playbook confere se ele já foi reiniciado depois da execução travada.
    var ESPERAS_MS = [2000, 5000];
    var tentativas = 1;
    var resultado = chamarEda();
    while (!resultado.ok && resultado.repetir && tentativas <= ESPERAS_MS.length) {
        gs.sleep(ESPERAS_MS[tentativas - 1]);
        tentativas++;
        resultado = chamarEda();
    }

    var nota = resultado.nota;
    if (resultado.ok) {
        nota += (tentativas > 1 ? ', na tentativa ' + tentativas : '') + '.';
    } else {
        nota += ' (' + tentativas + (tentativas > 1 ? ' tentativas' : ' tentativa') +
            '). O job não foi reiniciado: encaminhar para a sustentação.';
    }
    anotar({ work_notes: nota });
})(current, previous);
