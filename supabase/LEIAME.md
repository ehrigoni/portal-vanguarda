# Cadastro de usuários no Supabase

O site guarda as contas de vanguardistas e apoiadores no Supabase. Enquanto as chaves não estiverem no `index.html`, as telas de Entrar e Cadastrar-se aparecem, mas avisam que o cadastro está sendo ligado.

## Ligar o cadastro (uma vez)

1. Crie um projeto em https://supabase.com (região São Paulo, se possível).
2. Em **SQL Editor > New query**, cole o conteúdo de `schema.sql` e clique em **Run**.
3. Em **Authentication > Sign In / Providers > Email**, deixe o provedor **Email** ligado e **desligue "Confirm email"**. O login é por celular ou e-mail com senha; o site usa um e-mail interno para cada conta e nenhum e-mail é enviado.
4. Em **Project Settings > API**, copie a **Project URL** e a chave **anon public**.
5. No `index.html`, preencha `SUPABASE_URL` e `SUPABASE_ANON_KEY` (a chave anon é pública, pode ficar no site).

## Onde ficam os dados

- Tabela `perfis`: tipo (vanguardista ou apoiador), nome, celular, e-mail (opcional), CPF ou CNPJ, cidade e estado. Cada pessoa só lê e altera o próprio perfil.
- As senhas ficam no Supabase Auth, nunca na tabela.
- Para ver os cadastros: **Table Editor > perfis**.

## Redirecionamento

- Vanguardista: entra direto na área de simuladores (`#simuladores`).
- Apoiador: entra direto na área de apoiar vanguardistas (`#apoiadores`).
