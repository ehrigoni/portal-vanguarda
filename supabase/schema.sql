-- Portal Vanguarda: contas de vanguardistas e apoiadores
-- Rode este arquivo uma vez no Supabase: SQL Editor > New query > colar > Run.

-- 1. Perfis (um por conta)
create table if not exists public.perfis (
  id         uuid primary key references auth.users (id) on delete cascade,
  tipo       text not null check (tipo in ('vanguardista', 'apoiador')),
  nome       text not null check (length(trim(nome)) > 0),
  fone       text not null unique check (fone ~ '^[0-9]{10,11}$'),
  email      text unique,
  doc        text not null check (doc ~ '^([0-9]{11}|[0-9]{14})$'),
  cidade     text not null,
  uf         char(2) not null,
  criado_em  timestamptz not null default now()
);

-- Perfil do negócio do vanguardista (opcional). É o único dado de vanguardistas que chega aos
-- apoiadores, e só somado em grupos de 5 ou mais (supabase/painel.sql). Nunca nome, CPF/CNPJ ou contato.
alter table public.perfis add column if not exists porte_negocio text
  check (porte_negocio in ('autonomo', 'mei', 'me', 'epp', 'media'));
alter table public.perfis add column if not exists ramo text
  check (ramo in ('comercio', 'alimentacao', 'servicos', 'tecnologia', 'industria', 'educacao', 'saude', 'financas', 'construcao', 'outro'));
alter table public.perfis add column if not exists faturamento text
  check (faturamento in ('ate5k', '5a20k', '20a50k', '50a100k', 'acima100k'));

-- Endereço (CEP, rua, bairro, número, complemento). Obrigatório nos cadastros novos pelo site;
-- fica vazio nas contas antigas até a pessoa atualizar (por exemplo, ao apoiar logada).
alter table public.perfis add column if not exists cep         text check (cep ~ '^[0-9]{8}$');
alter table public.perfis add column if not exists rua         text;
alter table public.perfis add column if not exists bairro      text;
alter table public.perfis add column if not exists numero      text;
alter table public.perfis add column if not exists complemento text;

alter table public.perfis enable row level security;

drop policy if exists "ver o proprio perfil" on public.perfis;
create policy "ver o proprio perfil" on public.perfis
  for select using (auth.uid() = id);

drop policy if exists "editar o proprio perfil" on public.perfis;
create policy "editar o proprio perfil" on public.perfis
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- 1b. Administradores do portal. Não têm perfil: o login (só números) e o e-mail interno ficam aqui, a senha
--     só no Supabase Auth (guardada como hash). Ninguém do site lê ou grava esta tabela; o administrador
--     é cadastrado pelo SQL Editor (ver supabase/LEIAME.md). Quem decide o acesso é o banco (is_admin).
create table if not exists public.admins (
  email     text primary key check (email = lower(trim(email)) and position('@' in email) > 1),
  login     text not null unique check (login ~ '^[0-9]{3,11}$'),
  criado_em timestamptz not null default now()
);
alter table public.admins enable row level security; -- sem políticas
revoke all on public.admins from anon, authenticated;

create or replace function public.is_admin()
returns boolean
language sql
stable
security definer
set search_path = public, auth
as $$
  select auth.uid() is not null and exists (
    select 1 from public.admins a join auth.users u on lower(u.email) = a.email where u.id = auth.uid());
$$;

-- 2. Cria o perfil junto com a conta, com os dados enviados no cadastro
create or replace function public.criar_perfil()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  -- conta de administrador (criada pelo painel do Supabase): não tem perfil
  if exists (select 1 from public.admins where email = lower(new.email)) then return new; end if;
  insert into public.perfis (id, tipo, nome, fone, email, doc, cidade, uf, porte_negocio, ramo, faturamento,
                             cep, rua, bairro, numero, complemento)
  values (
    new.id,
    new.raw_user_meta_data ->> 'tipo',
    trim(new.raw_user_meta_data ->> 'nome'),
    regexp_replace(coalesce(new.raw_user_meta_data ->> 'fone', ''), '[^0-9]', '', 'g'),
    nullif(lower(trim(coalesce(new.raw_user_meta_data ->> 'email_contato', ''))), ''),
    regexp_replace(coalesce(new.raw_user_meta_data ->> 'doc', ''), '[^0-9]', '', 'g'),
    trim(new.raw_user_meta_data ->> 'cidade'),
    upper(new.raw_user_meta_data ->> 'uf'),
    case when new.raw_user_meta_data ->> 'porte_negocio' in ('autonomo', 'mei', 'me', 'epp', 'media')
         then new.raw_user_meta_data ->> 'porte_negocio' end,
    case when new.raw_user_meta_data ->> 'ramo' in ('comercio', 'alimentacao', 'servicos', 'tecnologia', 'industria', 'educacao', 'saude', 'financas', 'construcao', 'outro')
         then new.raw_user_meta_data ->> 'ramo' end,
    case when new.raw_user_meta_data ->> 'faturamento' in ('ate5k', '5a20k', '20a50k', '50a100k', 'acima100k')
         then new.raw_user_meta_data ->> 'faturamento' end,
    (select c from (select regexp_replace(coalesce(new.raw_user_meta_data ->> 'cep', ''), '[^0-9]', '', 'g') as c) x where c ~ '^[0-9]{8}$'),
    nullif(left(trim(coalesce(new.raw_user_meta_data ->> 'rua', '')), 160), ''),
    nullif(left(trim(coalesce(new.raw_user_meta_data ->> 'bairro', '')), 80), ''),
    nullif(left(trim(coalesce(new.raw_user_meta_data ->> 'numero', '')), 10), ''),
    nullif(left(trim(coalesce(new.raw_user_meta_data ->> 'complemento', '')), 60), '')
  );
  return new;
end;
$$;

drop trigger if exists ao_criar_usuario on auth.users;
create trigger ao_criar_usuario
  after insert on auth.users
  for each row execute function public.criar_perfil();

-- 3. Entrar com celular/WhatsApp ou e-mail: devolve o e-mail interno de login
create or replace function public.email_de_login(contato text)
returns text
language sql
stable
security definer
set search_path = public, auth
as $$
  select u.email
  from public.perfis p
  join auth.users u on u.id = p.id
  where (position('@' in contato) = 0 and p.fone = regexp_replace(contato, '[^0-9]', '', 'g'))
     or (position('@' in contato) > 0 and p.email = lower(trim(contato)))
  union all
  select a.email from public.admins a
  where position('@' in contato) = 0 and a.login = regexp_replace(contato, '[^0-9]', '', 'g')
  limit 1;
$$;

-- 4. Avisa antes do cadastro se o número ou o e-mail já têm conta
create or replace function public.contato_em_uso(p_fone text, p_email text)
returns text
language sql
stable
security definer
set search_path = public
as $$
  select case
    when exists (select 1 from public.perfis where fone = regexp_replace(coalesce(p_fone, ''), '[^0-9]', '', 'g')) then 'fone'
    when nullif(trim(coalesce(p_email, '')), '') is not null
         and exists (select 1 from public.perfis where email = lower(trim(p_email))) then 'email'
    else null
  end;
$$;

-- 4b. Quais dados do formulário já estão em outra conta (celular, e-mail, CPF/CNPJ). Devolve só os nomes
--     dos campos ('fone', 'email', 'doc'), nunca dados da outra conta. Logado, a própria conta não conta.
create or replace function public.dados_em_uso(p_fone text, p_email text, p_doc text)
returns text[]
language sql
stable
security definer
set search_path = public
as $$
  select array_remove(array[
    case when nullif(regexp_replace(coalesce(p_fone, ''), '[^0-9]', '', 'g'), '') is not null
          and exists (select 1 from public.perfis where fone = regexp_replace(p_fone, '[^0-9]', '', 'g')
                      and id is distinct from auth.uid()) then 'fone' end,
    case when nullif(trim(coalesce(p_email, '')), '') is not null
          and exists (select 1 from public.perfis where email = lower(trim(p_email))
                      and id is distinct from auth.uid()) then 'email' end,
    case when nullif(regexp_replace(coalesce(p_doc, ''), '[^0-9]', '', 'g'), '') is not null
          and exists (select 1 from public.perfis where doc = regexp_replace(p_doc, '[^0-9]', '', 'g')
                      and id is distinct from auth.uid()) then 'doc' end
  ], null);
$$;

revoke all on function public.email_de_login(text) from public;
revoke all on function public.contato_em_uso(text, text) from public;
grant execute on function public.email_de_login(text) to anon, authenticated;
grant execute on function public.contato_em_uso(text, text) to anon, authenticated;
revoke all on function public.dados_em_uso(text, text, text) from public;
grant execute on function public.dados_em_uso(text, text, text) to anon, authenticated;
revoke all on function public.criar_perfil() from public, anon, authenticated;
revoke all on function public.is_admin() from public;
grant execute on function public.is_admin() to anon, authenticated;

-- 5. Permissões explícitas da Data API (versão atual do Supabase, Postgres 17).
--    Projetos novos podem vir sem permissões automáticas nas tabelas novas; o site só lê e edita o próprio perfil
--    (o RLS acima limita às linhas da pessoa). O cadastro grava pelo gatilho, que roda como dono da tabela.
revoke all on public.perfis from anon, authenticated;
grant select, update on public.perfis to authenticated;
grant all on public.perfis to service_role;
