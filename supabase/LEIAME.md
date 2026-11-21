# Cadastro de usuários no Supabase

O site guarda as contas de vanguardistas e apoiadores no Supabase. Enquanto as chaves não estiverem no `index.html`, as telas de Entrar e Cadastrar-se aparecem, mas avisam que o cadastro está sendo ligado.

## Ligar o cadastro (uma vez)

1. Crie um projeto em https://supabase.com (região São Paulo, se possível).
2. Em **SQL Editor > New query**, cole o conteúdo de `schema.sql` e clique em **Run**.
3. Em **Authentication > Sign In / Providers > Email**, deixe o provedor **Email** ligado e **desligue "Confirm email"**. O login é por celular ou e-mail com senha; o site usa um e-mail interno para cada conta e nenhum e-mail é enviado.
4. Em **Project Settings > API**, copie a **Project URL** e a chave **anon public**.
5. No `index.html`, preencha `SUPABASE_URL` e `SUPABASE_ANON_KEY` (a chave anon é pública, pode ficar no site).
6. Painel do apoiador: em **SQL Editor > New query**, cole o conteúdo de `painel.sql` e clique em **Run** (pode rodar de novo sem perder dados). Enquanto isso não for feito, o painel guarda perfil e selos só no navegador e mostra os grupos como "em breve".
7. Registro dos apoios: em **Project Settings > API Keys**, copie a chave **service_role** (ou a **secret key**) e cole na Vercel como `SUPABASE_SERVICE_ROLE_KEY` (Production). Essa chave é secreta: só na Vercel, nunca no código. Depois, faça um redeploy.

## Onde ficam os dados

- Tabela `perfis`: tipo (vanguardista ou apoiador), nome, celular, e-mail (opcional), CPF ou CNPJ, cidade e estado. Cada pessoa só lê e altera o próprio perfil.
- As senhas ficam no Supabase Auth, nunca na tabela.
- Tabela `apoiador_perfil`: marca, número de apadrinhados, porte, setor, objetivos e selos escolhidos pelo apoiador (usados na recomendação de selos e no material de divulgação). Cada apoiador só lê e altera o próprio.
- Tabela `atividades`: um registro por dia e por tipo quando o vanguardista logado usa um simulador ou clica em Indique. É a base do desempenho agregado.
- Tabela `grupos`: filtros (estado, cidade, CPF ou CNPJ) que o apoiador escolheu acompanhar. Nunca guarda uma lista de pessoas.
- Tabela `apoios`: um registro por pagamento de apoio confirmado no Asaas (CPF/CNPJ, vanguardistas, meses, valor, data, ambiente sandbox ou produção, estorno). Quem grava é o webhook `api/asaas/webhook.js`, com a chave de serviço; ninguém lê pelo site.
- Tabela `apoio_vanguardistas`: liga cada apoio aos vanguardistas cadastrados que ele custeia. A função `alocar_apoios` distribui as vagas dando preferência a quem tem menos apoios, e roda a cada pagamento e a cada novo vanguardista.
- Função `impacto_apoiador`: números do painel e do material, calculados a partir dos apoios do CPF/CNPJ do apoiador. Regiões vêm dos vanguardistas custeados: estado só com 5 ou mais vanguardistas, cidade só com 5 ou mais; o resto vira "outras regiões".
- Página pública do selo: cada apoiador tem um `codigo` em `apoiador_perfil`. O link do material (`/?selo=codigo`) abre a página do selo com os números atuais (função `selo_publico`), conta visitas por dia (`selo_visitas`) e grava em `perfis.indicado_por` quem se cadastrou vindo dele.
- Funções `contar_grupo` e `painel_grupo`: devolvem só totais e percentuais do grupo. Nada sai quando o grupo tem menos de 5 vanguardistas, ou quando, tirando um filtro, a diferença entre os grupos isolaria de 1 a 4 pessoas. O apoiador não tem acesso de leitura a `perfis` nem a `atividades` de vanguardistas.
- Para ver os cadastros: **Table Editor > perfis**.

## Redirecionamento

- Vanguardista: entra direto na área de simuladores (`#simuladores`).
- Apoiador: entra direto no painel do apoiador (`#painel`): selos sociais recomendados, material de divulgação e grupos de vanguardistas.
