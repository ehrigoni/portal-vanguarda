# Cadastro de usuários no Supabase

O site guarda as contas de vanguardistas e apoiadores no Supabase. Enquanto as chaves não estiverem no `index.html`, as telas de Entrar e Cadastrar-se aparecem, mas avisam que o cadastro está sendo ligado.

## Ligar o cadastro (uma vez)

1. Crie um projeto em https://supabase.com (região São Paulo, se possível).
2. Em **SQL Editor > New query**, cole o conteúdo de `schema.sql` e clique em **Run**.
3. Em **Authentication > Sign In / Providers > Email**, deixe o provedor **Email** ligado e **desligue "Confirm email"**. O login é por celular ou e-mail com senha; o site usa um e-mail interno para cada conta e nenhum e-mail é enviado.
4. Em **Project Settings > API**, copie a **Project URL** e a chave **anon public**.
5. No `index.html`, preencha `SUPABASE_URL` e `SUPABASE_ANON_KEY` (a chave anon é pública, pode ficar no site).
6. Painel do apoiador: em **SQL Editor > New query**, cole o conteúdo de `painel.sql` e clique em **Run**. Pode rodar de novo; a única coisa que ele apaga é a tabela antiga `atividades`. Enquanto isso não for feito, o painel guarda perfil e selos só no navegador e mostra os grupos como "em breve".
7. Registro dos apoios: em **Project Settings > API Keys**, copie a chave **service_role** (ou a **secret key**) e cole na Vercel como `SUPABASE_SERVICE_ROLE_KEY` (Production). Essa chave é secreta: só na Vercel, nunca no código. Depois, faça um redeploy.

## Onde ficam os dados

- Tabela `perfis`: tipo (vanguardista ou apoiador), nome, celular, e-mail, CPF ou CNPJ, CEP, rua, bairro, número, complemento, cidade e estado. Ao mudar o `schema.sql`, rode-o de novo no SQL Editor (não apaga dados). Vanguardistas também podem informar, de forma opcional, porte, tipo de negócio e faixa de faturamento. Cada pessoa só lê e altera o próprio perfil.
- As senhas ficam no Supabase Auth, nunca na tabela.
- Tabela `apoiador_perfil`: marca, número de apadrinhados, porte, setor, objetivos e selos escolhidos pelo apoiador (usados na recomendação de selos e no material de divulgação). Cada apoiador só lê e altera o próprio.
- Tabela `atividades`: desativada. O `painel.sql` apaga a tabela e o site não registra mais o uso dos simuladores (LGPD, minimização de dados).
- Tabela `grupos`: filtros (estado, cidade, CPF ou CNPJ) que o apoiador escolheu acompanhar. Nunca guarda uma lista de pessoas.
- Tabela `apoios`: um registro por pagamento de apoio confirmado no Asaas (CPF/CNPJ, celular e e-mail do cliente, vanguardistas, meses, valor, data, ambiente sandbox ou produção, estorno). Quem grava é o webhook `api/asaas/webhook.js`, com a chave de serviço; ninguém lê pelo site. O apoio só conta no painel da conta com o mesmo CPF/CNPJ e o mesmo celular ou e-mail, para ninguém ver o apoio de outra empresa só por saber o CNPJ dela.
- Tabela `apoio_vanguardistas`: liga cada apoio aos vanguardistas cadastrados que ele custeia. A função `alocar_apoios` distribui as vagas dando preferência a quem tem menos apoios, e roda a cada pagamento e a cada novo vanguardista.
- Função `impacto_apoiador`: números do painel e do material, calculados a partir dos apoios do CPF/CNPJ do apoiador. Regiões vêm dos vanguardistas custeados: estado só com 5 ou mais vanguardistas, cidade só com 5 ou mais; o resto vira "outras regiões".
- Selos: nenhum é livre. Todos exigem pelo menos 1 apoio pago e não estornado confirmado no Asaas (campo `apoios` do impacto) para serem selecionados, gerados e divulgados; sem isso o painel mostra todos como "Bloqueado", a tag "Recomendado para você" só vai em selos liberados e a página pública não mostra nenhum selo. O gatilho `validar_selos` descarta selo novo sem apoio confirmado; a escolha já salva continua no banco se o apoio for estornado, mas fica fora da exibição até a regularização. Referência completa em `docs/selos.md`.
- Selo Powered by: além do apoio confirmado, só pode ser usado por quem pagou pelo menos 180 meses de uso do portal (vanguardistas × meses, somando os apoios pagos e não estornados, com qualquer número de vanguardistas; campo `meses_vanguardista` do impacto). Antes disso o painel mostra o selo bloqueado, com a exigência, e ele não entra no material; a página pública do selo também o esconde.
- Página pública do selo: cada apoiador tem um `codigo` em `apoiador_perfil`. O link do material (`/?selo=codigo`) abre a página do selo com os números atuais (função `selo_publico`), conta visitas por dia (`selo_visitas`) e grava em `perfis.indicado_por` quem se cadastrou vindo dele.
- Funções `contar_grupo` e `painel_grupo`: devolvem só o total do grupo e a distribuição por porte, tipo de negócio e faixa de faturamento. Nada sai quando o grupo tem menos de 5 vanguardistas, ou quando, tirando um filtro, a diferença entre os grupos isolaria de 1 a 4 pessoas. O apoiador não tem acesso de leitura a `perfis` de vanguardistas.

## Privacidade dos vanguardistas (LGPD)

- Dos vanguardistas, o apoiador só recebe região (estado e cidade), porte, tipo de negócio e faixa de faturamento, sempre somados (função interna `_perfil_somado`).
- Cada número reúne pelo menos 5 vanguardistas. Faixas menores vão para "outros"; se "outros" ficar entre 1 e 4, a menor faixa grande também vai para lá, para ninguém descobrir um grupo pequeno subtraindo do total.
- Nome, CPF/CNPJ, celular, e-mail e qualquer registro de uso nunca saem do banco para o navegador de outra pessoa.
- Os logs da Vercel não guardam o corpo de erro do banco nem do Asaas (que pode repetir CPF/CNPJ, celular ou e-mail), nem o link do PDF das notas fiscais.
- Para ver os cadastros: **Table Editor > perfis**.

## Redirecionamento

- Vanguardista: entra direto na área de simuladores (`#simuladores`).
- Apoiador: entra direto no painel do apoiador (`#painel`): selos sociais recomendados, material de divulgação e grupos de vanguardistas.

## Versão do Supabase

Testado no Supabase atual (imagem `supabase/postgres:17.12.0.002`, Postgres 17.12), com o cadastro feito pelo papel do Auth (`supabase_auth_admin`), o apoiador logado (`authenticated`), visitante (`anon`) e o webhook (`service_role`). Os dois arquivos dão as permissões das tabelas explicitamente, então funcionam também em projetos novos com "expor tabelas novas automaticamente" desligado na Data API: o site só lê e edita o próprio perfil, o perfil de apoiador e os grupos; `apoios`, `apoio_vanguardistas` e `selo_visitas` ficam só para a chave de serviço e as funções do banco.

## Excluir a própria conta

O botão **Excluir minha conta** (abas Vanguardistas e Apoiar, só para quem está logado) chama a função `excluir_minha_conta()` do `painel.sql`. Ela só age sobre a conta logada (`auth.uid()`), sem receber nenhum id do site, e só a role `authenticated` pode executá-la. Ela apaga:

- os apoios da pessoa (mesmo CPF/CNPJ e mesmo celular ou e-mail, a regra do painel) e as visitas do selo dela;
- o usuário em `auth.users`, o que leva em cascata `perfis`, `apoiador_perfil`, `grupos` e os vínculos em `apoio_vanguardistas`.

Depois roda `alocar_apoios` para passar a outros vanguardistas as vagas que ficaram livres. Cobranças e notas fiscais já emitidas continuam no Asaas, fora do banco do portal. Enquanto o `painel.sql` novo não for rodado no Supabase, o botão mostra um aviso de erro e não apaga nada.

## Administrador (aba Administrador)

A aba **Administrador** fica em www.vanguarda.social.br/admin (o `vercel.json` reescreve `/admin` para o `index.html`) e tem cinco painéis retráteis: Simuladores (quais aparecem no site), Selos, Impacto, Apoiadores e Usuários. Ela só aparece para a conta de administrador. Quem libera ou barra cada consulta é o banco: todas as funções de `admin.sql` conferem `is_admin()` antes de responder, então uma conta comum recebe "apenas administradores" mesmo chamando a função direto.

A conta de administrador não tem perfil de vanguardista nem de apoiador e não entra nos números do portal. O login de administrador (só números, de 3 a 11 dígitos) fica na tabela `admins`. A senha fica só no Supabase Auth, guardada como hash, e nunca vai para o código ou para um arquivo SQL.

Para criar o administrador, uma vez:

1. Rode no SQL Editor `schema.sql`, depois `painel.sql` e depois `admin.sql`.
2. Ainda no SQL Editor, cadastre o login e o e-mail interno da conta, trocando `<e-mail interno>` e `<login>` pelos valores escolhidos (o e-mail não recebe mensagens; ele é usado só por dentro do login):
   ```sql
   insert into public.admins (email, login) values ('<e-mail interno>', '<login>');
   ```
3. Em **Authentication > Users > Add user > Create new user**, use o mesmo e-mail, digite a senha e marque **Auto Confirm User**. Faça este passo depois do passo 2: com o e-mail já na tabela `admins`, o cadastro não tenta criar um perfil.
4. Abra www.vanguarda.social.br/admin, clique em **Entrar** e use o login escolhido e a senha. Quem não é administrador vê "Acesso negado".

Para trocar a senha: **Authentication > Users**, abra o usuário e use **Reset password**, ou exclua e crie de novo (os passos 3 e 4). Para tirar o acesso: `delete from public.admins where login = '<login>';`.

### Tornar administradora uma conta que já existe no site

Uma conta criada pelo Cadastre-se também pode ser administradora: ela continua entrando com o próprio celular ou e-mail e passa a ver a aba Administrador. No SQL Editor, troque `<e-mail da conta>` pelo e-mail cadastrado no perfil:

```sql
alter table public.admins alter column login drop not null;
insert into public.admins (email)
select lower(u.email) from auth.users u left join public.perfis p on p.id = u.id
where lower(u.email) = '<e-mail da conta>' or p.email = '<e-mail da conta>'
on conflict (email) do nothing;
```

Para tirar o acesso: `delete from public.admins where email = (select lower(u.email) from auth.users u join public.perfis p on p.id = u.id where p.email = '<e-mail da conta>');`.
