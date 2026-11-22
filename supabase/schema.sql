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

alter table public.perfis enable row level security;

drop policy if exists "ver o proprio perfil" on public.perfis;
create policy "ver o proprio perfil" on public.perfis
  for select using (auth.uid() = id);

drop policy if exists "editar o proprio perfil" on public.perfis;
create policy "editar o proprio perfil" on public.perfis
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- 2. Cria o perfil junto com a conta, com os dados enviados no cadastro
create or replace function public.criar_perfil()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  insert into public.perfis (id, tipo, nome, fone, email, doc, cidade, uf, porte_negocio, ramo, faturamento)
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
         then new.raw_user_meta_data ->> 'faturamento' end
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

revoke all on function public.email_de_login(text) from public;
revoke all on function public.contato_em_uso(text, text) from public;
grant execute on function public.email_de_login(text) to anon, authenticated;
grant execute on function public.contato_em_uso(text, text) to anon, authenticated;
