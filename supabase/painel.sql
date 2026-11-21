-- Portal Vanguarda: painel do apoiador (selos sociais, material de divulgação e grupos de vanguardistas)
-- Rode este arquivo no Supabase DEPOIS do schema.sql: SQL Editor > New query > colar > Run.
-- Pode rodar de novo sem perder dados (tudo é "if not exists" / "or replace").
--
-- Privacidade: o apoiador nunca lê dados de um vanguardista. Ele só recebe números do grupo inteiro,
-- calculados aqui no banco, e só quando o grupo tem pelo menos 5 vanguardistas (constante MIN_GRUPO abaixo).

-- 1. Perfil do apoiador para recomendar selos e guardar os selos escolhidos
create table if not exists public.apoiador_perfil (
  id            uuid primary key references public.perfis (id) on delete cascade,
  marca         text check (length(marca) <= 80),
  porte         text check (porte in ('autonomo', 'mei', 'me', 'epp', 'media')),
  setor         text check (length(setor) <= 40),
  objetivos     text[] not null default '{}',
  selos         text[] not null default '{}',
  atualizado_em timestamptz not null default now()
);

alter table public.apoiador_perfil add column if not exists marca text check (length(marca) <= 80);

alter table public.apoiador_perfil enable row level security;

drop policy if exists "apoiador ve o proprio perfil" on public.apoiador_perfil;
create policy "apoiador ve o proprio perfil" on public.apoiador_perfil
  for select using (auth.uid() = id);

drop policy if exists "apoiador cria o proprio perfil" on public.apoiador_perfil;
create policy "apoiador cria o proprio perfil" on public.apoiador_perfil
  for insert with check (
    auth.uid() = id
    and exists (select 1 from public.perfis p where p.id = auth.uid() and p.tipo = 'apoiador')
  );

drop policy if exists "apoiador edita o proprio perfil" on public.apoiador_perfil;
create policy "apoiador edita o proprio perfil" on public.apoiador_perfil
  for update using (auth.uid() = id) with check (auth.uid() = id);

-- 2. Atividade dos vanguardistas (base do desempenho agregado)
--    No máximo um registro por tipo por dia para cada vanguardista.
create table if not exists public.atividades (
  id              bigint generated always as identity primary key,
  vanguardista_id uuid not null default auth.uid() references public.perfis (id) on delete cascade,
  tipo            text not null check (tipo in ('simulador_preco', 'simulador_meta', 'indicacao')),
  dia             date not null default (now() at time zone 'America/Sao_Paulo')::date,
  unique (vanguardista_id, tipo, dia)
);

create index if not exists atividades_dia on public.atividades (dia);

alter table public.atividades enable row level security;

drop policy if exists "vanguardista registra a propria atividade" on public.atividades;
create policy "vanguardista registra a propria atividade" on public.atividades
  for insert with check (
    vanguardista_id = auth.uid()
    and dia = (now() at time zone 'America/Sao_Paulo')::date
    and exists (select 1 from public.perfis p where p.id = auth.uid() and p.tipo = 'vanguardista')
  );

drop policy if exists "vanguardista ve a propria atividade" on public.atividades;
create policy "vanguardista ve a propria atividade" on public.atividades
  for select using (vanguardista_id = auth.uid());

-- 3. Grupos de vanguardistas que o apoiador acompanha.
--    O grupo é um filtro (estado, cidade, pessoa física ou jurídica), nunca uma lista de pessoas.
create table if not exists public.grupos (
  id          uuid primary key default gen_random_uuid(),
  apoiador_id uuid not null default auth.uid() references public.perfis (id) on delete cascade,
  nome        text not null check (length(trim(nome)) between 1 and 60),
  uf          char(2),
  cidade      text check (length(cidade) <= 80),
  tipo_doc    text check (tipo_doc in ('cpf', 'cnpj')),
  criado_em   timestamptz not null default now()
);

alter table public.grupos enable row level security;

drop policy if exists "apoiador ve os proprios grupos" on public.grupos;
create policy "apoiador ve os proprios grupos" on public.grupos
  for select using (apoiador_id = auth.uid());

drop policy if exists "apoiador cria grupos" on public.grupos;
create policy "apoiador cria grupos" on public.grupos
  for insert with check (
    apoiador_id = auth.uid()
    and exists (select 1 from public.perfis p where p.id = auth.uid() and p.tipo = 'apoiador')
    and (select count(*) from public.grupos g where g.apoiador_id = auth.uid()) < 20
  );

drop policy if exists "apoiador apaga os proprios grupos" on public.grupos;
create policy "apoiador apaga os proprios grupos" on public.grupos
  for delete using (apoiador_id = auth.uid());

-- comparação de cidade sem acento, sem depender da extensão unaccent
create or replace function public.unaccent_safe(t text)
returns text
language sql
immutable
as $$
  select translate(coalesce(t, ''),
    'áàâãäéèêëíìîïóòôõöúùûüçÁÀÂÃÄÉÈÊËÍÌÎÏÓÒÔÕÖÚÙÛÜÇ',
    'aaaaaeeeeiiiiooooouuuucAAAAAEEEEIIIIOOOOOUUUUC');
$$;

-- 4. Quem entra num grupo (uso interno das funções abaixo; não fica exposto)
create or replace function public._membros_grupo(p_uf text, p_cidade text, p_tipo_doc text)
returns table (id uuid)
language sql
stable
security definer
set search_path = public
as $$
  select p.id
  from public.perfis p
  where p.tipo = 'vanguardista'
    and (nullif(trim(coalesce(p_uf, '')), '') is null or p.uf = upper(trim(p_uf)))
    and (nullif(trim(coalesce(p_cidade, '')), '') is null
         or lower(unaccent_safe(p.cidade)) = lower(unaccent_safe(trim(p_cidade))))
    and (p_tipo_doc is null
         or (p_tipo_doc = 'cpf' and length(p.doc) = 11)
         or (p_tipo_doc = 'cnpj' and length(p.doc) = 14));
$$;

-- 4b. Um grupo só é mostrado se tiver pelo menos 5 vanguardistas E se, tirando qualquer um dos filtros,
--     a diferença entre os dois grupos for 0 ou pelo menos 5. Isso impede descobrir uma pessoa
--     subtraindo um grupo de outro (ex.: "RS" menos "RS, pessoa jurídica" = 1 vanguardista).
create or replace function public._grupo_seguro(p_uf text, p_cidade text, p_tipo_doc text, p_min integer)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  n integer;
  m integer;
begin
  select count(*) into n from public._membros_grupo(p_uf, p_cidade, p_tipo_doc);
  if n < p_min then return null; end if;
  if nullif(trim(coalesce(p_uf, '')), '') is not null then
    select count(*) into m from public._membros_grupo(null, p_cidade, p_tipo_doc);
    if m - n between 1 and p_min - 1 then return null; end if;
  end if;
  if nullif(trim(coalesce(p_cidade, '')), '') is not null then
    select count(*) into m from public._membros_grupo(p_uf, null, p_tipo_doc);
    if m - n between 1 and p_min - 1 then return null; end if;
  end if;
  if p_tipo_doc is not null then
    select count(*) into m from public._membros_grupo(p_uf, p_cidade, null);
    if m - n between 1 and p_min - 1 then return null; end if;
  end if;
  return n;
end;
$$;

-- 5. Tamanho de um grupo antes de salvar. Se o grupo não for seguro (ver 4b), devolve null.
create or replace function public.contar_grupo(p_uf text, p_cidade text, p_tipo_doc text)
returns integer
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  MIN_GRUPO constant integer := 5;
  n integer;
begin
  if not exists (select 1 from public.perfis where id = auth.uid() and tipo = 'apoiador') then
    raise exception 'apenas apoiadores';
  end if;
  return public._grupo_seguro(p_uf, p_cidade, p_tipo_doc, MIN_GRUPO);
end;
$$;

-- 6. Desempenho agregado de um grupo do próprio apoiador.
--    Devolve só totais, médias e percentuais do grupo; nada por pessoa.
create or replace function public.painel_grupo(p_grupo uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  MIN_GRUPO constant integer := 5;
  g public.grupos;
  n integer;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  r jsonb;
begin
  select * into g from public.grupos where id = p_grupo and apoiador_id = auth.uid();
  if not found then raise exception 'grupo não encontrado'; end if;

  n := public._grupo_seguro(g.uf, g.cidade, g.tipo_doc, MIN_GRUPO);

  if n is null then
    return jsonb_build_object('suficiente', false, 'minimo', MIN_GRUPO);
  end if;

  with m as (
    select id from public._membros_grupo(g.uf, g.cidade, g.tipo_doc)
  ),
  a as (
    select a.* from public.atividades a join m on m.id = a.vanguardista_id
    where a.dia > hoje - 56
  ),
  semanas as (
    select s.k,
           count(distinct a.vanguardista_id) as ativos,
           count(a.id) filter (where a.tipo like 'simulador%') as simulacoes
    from generate_series(7, 0, -1) as s(k)
    left join a on a.dia > hoje - 7 * (s.k + 1) and a.dia <= hoje - 7 * s.k
    group by s.k
  )
  select jsonb_build_object(
    'suficiente', true,
    'vanguardistas', n,
    'ativos_30d', (select count(distinct vanguardista_id) from a where dia > hoje - 30),
    'usaram_simulador_30d', (select count(distinct vanguardista_id) from a where dia > hoje - 30 and tipo like 'simulador%'),
    'indicaram_30d', (select count(distinct vanguardista_id) from a where dia > hoje - 30 and tipo = 'indicacao'),
    'simulacoes_30d', (select count(*) from a where dia > hoje - 30 and tipo like 'simulador%'),
    'indicacoes_30d', (select count(*) from a where dia > hoje - 30 and tipo = 'indicacao'),
    'semanas', (select jsonb_agg(jsonb_build_object('k', k, 'ativos', ativos, 'simulacoes', simulacoes) order by k desc) from semanas)
  ) into r;

  return r;
end;
$$;

-- 7. Impacto do apoiador para o material de divulgação: regiões e desempenho, sempre agregados.
--    Base: a soma dos grupos que o apoiador acompanha; sem grupos, todos os vanguardistas do portal.
--    Só entram estados com pelo menos 5 vanguardistas; os demais viram "outras regiões", sem número.
create or replace function public.impacto_apoiador()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  MIN_GRUPO constant integer := 5;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  tem_grupos boolean;
  n integer;
  r jsonb;
begin
  if not exists (select 1 from public.perfis where id = auth.uid() and tipo = 'apoiador') then
    raise exception 'apenas apoiadores';
  end if;
  select exists (select 1 from public.grupos where apoiador_id = auth.uid()) into tem_grupos;

  with m as (
    select distinct mg.id
    from public.grupos g
    cross join lateral public._membros_grupo(g.uf, g.cidade, g.tipo_doc) mg
    where tem_grupos and g.apoiador_id = auth.uid()
      and public._grupo_seguro(g.uf, g.cidade, g.tipo_doc, MIN_GRUPO) is not null
    union
    select p.id from public.perfis p where not tem_grupos and p.tipo = 'vanguardista'
  )
  select count(*) into n from m;

  if n < MIN_GRUPO then
    return jsonb_build_object('suficiente', false, 'base', case when tem_grupos then 'grupos' else 'portal' end, 'minimo', MIN_GRUPO);
  end if;

  with m as (
    select distinct mg.id
    from public.grupos g
    cross join lateral public._membros_grupo(g.uf, g.cidade, g.tipo_doc) mg
    where tem_grupos and g.apoiador_id = auth.uid()
      and public._grupo_seguro(g.uf, g.cidade, g.tipo_doc, MIN_GRUPO) is not null
    union
    select p.id from public.perfis p where not tem_grupos and p.tipo = 'vanguardista'
  ),
  mp as (select p.* from public.perfis p join m on m.id = p.id),
  ufs as (select uf, count(*) as q from mp group by uf),
  a as (select a.* from public.atividades a join m on m.id = a.vanguardista_id where a.dia > hoje - 30)
  select jsonb_build_object(
    'suficiente', true,
    'base', case when tem_grupos then 'grupos' else 'portal' end,
    'vanguardistas', n,
    'regioes', coalesce((select jsonb_agg(jsonb_build_object('uf', uf, 'vanguardistas', q) order by q desc, uf) from ufs where q >= MIN_GRUPO), '[]'::jsonb),
    'outras_regioes', exists (select 1 from ufs where q < MIN_GRUPO),
    'cidades', (select count(distinct lower(public.unaccent_safe(cidade)) || uf) from mp),
    'ativos_30d', (select count(distinct vanguardista_id) from a),
    'simulacoes_30d', (select count(*) from a where tipo like 'simulador%'),
    'indicacoes_30d', (select count(*) from a where tipo = 'indicacao')
  ) into r;
  return r;
end;
$$;

revoke all on function public._membros_grupo(text, text, text) from public, anon, authenticated;
revoke all on function public._grupo_seguro(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.contar_grupo(text, text, text) from public;
revoke all on function public.painel_grupo(uuid) from public;
grant execute on function public.contar_grupo(text, text, text) to authenticated;
grant execute on function public.painel_grupo(uuid) to authenticated;
revoke all on function public.impacto_apoiador() from public;
grant execute on function public.impacto_apoiador() to authenticated;
