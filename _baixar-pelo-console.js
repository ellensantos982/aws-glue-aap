// Baixa os arquivos deste repositório pelo console do navegador, para ambientes em que o
// git clone e o download do zip não passam. Abra o console (F12), cole este arquivo inteiro e
// confirme quando o navegador pedir permissão para vários downloads.
//
// Os arquivos chegam com o caminho no nome (pasta__arquivo). Para remontar as pastas, mova-os
// para uma pasta vazia e rode dentro dela, no Git Bash:
//   for f in *__*; do d="${f//__//}"; mkdir -p "$(dirname "$d")"; mv "$f" "$d"; done
//
// Este arquivo é gerado junto com o repositório: a lista abaixo acompanha os arquivos publicados.
(async () => {
  const base = 'https://raw.githubusercontent.com/ellensantos982/aws-glue-aap/main/';
  const somente = 'para-copiar/';   // '' baixa o repositório inteiro
  const arquivos = [
    '.ansible-lint',
    '.env.exemplo',
    '.gitignore',
    'README.md',
    'ansible.cfg',
    'aws/glue/job_travavel.py',
    'aws/poc-glue-servicenow.yaml',
    'inventory.yml',
    'library/glue_job_run.py',
    'para-copiar/_AAP-pela-tela.md',
    'para-copiar/_LEIA-ME.md',
    'para-copiar/_ferramentas/aap_configurar.conf.exemplo',
    'para-copiar/_ferramentas/aap_configurar.sh',
    'para-copiar/playbooks/glue-playbooks/library/glue_job_run.py',
    'para-copiar/playbooks/glue-playbooks/restart_glue_job.yml',
    'para-copiar/playbooks/glue-playbooks/vars/restart_glue_job.yml',
    'para-copiar/rulebooks/glue-eventos-observar.yml',
    'para-copiar/rulebooks/servicenow-glue-aap.yml',
    'poc.sh',
    'requirements.yml',
    'restart_glue_job.yml',
    'rulebooks/servicenow-glue-aap.yml',
    'rulebooks/servicenow-glue-polling.yml',
    'rulebooks/servicenow-glue-webhook.yml',
    'setup/aap_configurar.conf.exemplo',
    'setup/aap_configurar.sh',
    'setup/aap_lab_configurar.ps1',
    'setup/aws.yml',
    'setup/destruir.yml',
    'setup/servicenow.yml',
    'setup/servicenow/acionar_eda.js',
    'setup/servicenow_url.yml',
    'simular_travamento.yml',
    'vars/vars.yml',
  ].filter(c => c.startsWith(somente));

  // Os .sh e .py não são baixados como arquivo: vêm em texto, de um markdown do repositório,
  // sem a primeira linha (a do interpretador), que é recolocada aqui.
  const primeiraLinha = { bash: '#' + '!/usr/bin/env bash', python: '#' + '!/usr/bin/python' };
  const emTexto = {};
  const md = await (await fetch(base + '_scripts-em-texto.md')).text();
  for (const m of md.matchAll(/<!-- arquivo: (.+?) \| interpretador: (\w+) -->\n````\w*\n([\s\S]*?)\n````\n/g)) {
    emTexto[m[1]] = (primeiraLinha[m[2]] ? primeiraLinha[m[2]] + '\n' : '') + m[3] + '\n';
  }

  const falhas = [];
  for (const [n, caminho] of arquivos.entries()) {
    try {
      let blob;
      if (caminho in emTexto) {
        blob = new Blob([emTexto[caminho]], { type: 'text/plain' });
      } else if (/\.(sh|py)$/.test(caminho)) {
        throw new Error('não está no markdown de scripts');
      } else {
        const r = await fetch(base + caminho);
        if (!r.ok) throw new Error(`HTTP ${r.status}`);
        blob = await r.blob();
      }
      const a = document.createElement('a');
      a.href = URL.createObjectURL(blob);
      a.download = caminho.slice(somente.length).replaceAll('/', '__');   // pasta/arquivo -> pasta__arquivo
      document.body.appendChild(a);
      a.click();
      a.remove();
      setTimeout(() => URL.revokeObjectURL(a.href), 10000);
      console.log(`${n + 1}/${arquivos.length} ${caminho}`);
    } catch (e) {
      falhas.push(caminho);
      console.error(`Falhou: ${caminho} (${e.message})`);
    }
    await new Promise(r => setTimeout(r, 400));
  }
  console.log(falhas.length ? `Terminou com ${falhas.length} falha(s):` : 'Terminou sem falhas.', falhas);
})();
