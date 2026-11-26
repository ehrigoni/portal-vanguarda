# Interpretação do passo a passo dos simuladores

No painel **Administrador > Simuladores**, ao clicar em **Salvar**, o texto "Passo a passo para executar o simulador" é enviado para `POST /api/simuladores/interpretar` (função da Vercel em `interpretar.js`). A função confere no Supabase que a sessão é de administrador (`rpc is_admin`), pede ao Claude os comandos em JSON e devolve. O painel grava os comandos junto com o simulador em `config_site.simuladores.<simulador>.comandos` e mostra a lista abaixo do passo a passo.

A interpretação só roda quando o passo a passo muda (ou quando ainda não há comandos salvos). Se falhar, o resto do simulador é salvo mesmo assim e o painel avisa; clicar em Salvar de novo tenta outra vez.

## Configurar

Vercel > projeto do portal > **Settings > Environment Variables**:

1. `ANTHROPIC_API_KEY`: chave da API do Claude (console.anthropic.com > API Keys). Marque como *Sensitive*. Nunca coloque a chave no código ou no `index.html`.
2. Opcional: `CLAUDE_MODELO` para trocar o modelo (padrão `claude-opus-5-5`).
3. Faça **Redeploy** do último deploy.

Sem a chave, o painel salva normalmente e avisa que o passo a passo não foi interpretado.

## Observação

`config_site` tem leitura pública (o site lê a configuração dos simuladores sem login), então o passo a passo e os comandos interpretados também podem ser lidos pela API pública do Supabase.
