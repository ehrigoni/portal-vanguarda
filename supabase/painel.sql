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

revoke all on function public._membros_grupo(text, text, text) from public, anon, authenticated;
revoke all on function public._grupo_seguro(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.contar_grupo(text, text, text) from public;
revoke all on function public.painel_grupo(uuid) from public;
grant execute on function public.contar_grupo(text, text, text) to authenticated;
grant execute on function public.painel_grupo(uuid) to authenticated;

-- 7. Apoios pagos. Quem grava é o webhook do Asaas (api/asaas/webhook.js), com a chave de serviço do
--    Supabase; o site não lê nem escreve nesta tabela. Conta só dinheiro que entrou.
create table if not exists public.apoios (
  pagamento_id  text primary key,
  ambiente      text not null check (ambiente in ('sandbox', 'producao')),
  doc           text not null check (doc ~ '^([0-9]{11}|[0-9]{14})$'),
  vanguardistas integer not null check (vanguardistas between 1 and 1000),
  meses         integer not null check (meses between 1 and 120),
  valor         numeric(12, 2) not null check (valor >= 0),
  pago_em       date not null,
  estornado_em  timestamptz,
  criado_em     timestamptz not null default now()
);
create index if not exists apoios_doc on public.apoios (doc, ambiente);
-- Contato do cliente no Asaas. O apoio só conta para a conta que tem o mesmo CPF/CNPJ E o mesmo
-- celular ou e-mail: o CPF/CNPJ sozinho não basta, porque um CNPJ é público e qualquer pessoa
-- poderia criar uma conta com ele para ver quanto aquela empresa apoiou.
alter table public.apoios add column if not exists fone text;
alter table public.apoios add column if not exists email text;
alter table public.apoios enable row level security; -- sem políticas: ninguém do site acessa

-- 8. Quais vanguardistas cadastrados cada apoio custeia (só o banco lê; o apoiador vê totais)
create table if not exists public.apoio_vanguardistas (
  pagamento_id    text not null references public.apoios (pagamento_id) on delete cascade,
  vanguardista_id uuid not null references public.perfis (id) on delete cascade,
  primary key (pagamento_id, vanguardista_id)
);
create index if not exists apoio_vanguardistas_vg on public.apoio_vanguardistas (vanguardista_id);
alter table public.apoio_vanguardistas enable row level security; -- sem políticas

-- Distribui os apoios ainda incompletos entre os vanguardistas cadastrados: primeiro quem tem menos
-- apadrinhamentos vigentes no mesmo ambiente, depois quem se cadastrou antes. Roda a cada apoio novo
-- e a cada vanguardista novo (quem se cadastra depois completa apoios que ficaram faltando).
create or replace function public.alocar_apoios()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
  a record;
  q integer;
  total integer := 0;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  for a in
    select ap.pagamento_id, ap.ambiente,
           ap.vanguardistas - (select count(*) from public.apoio_vanguardistas av where av.pagamento_id = ap.pagamento_id) as falta
    from public.apoios ap
    where ap.estornado_em is null
    order by ap.pago_em, ap.criado_em
  loop
    continue when a.falta <= 0;
    insert into public.apoio_vanguardistas (pagamento_id, vanguardista_id)
    select a.pagamento_id, p.id
    from public.perfis p
    where p.tipo = 'vanguardista'
      and not exists (select 1 from public.apoio_vanguardistas x where x.pagamento_id = a.pagamento_id and x.vanguardista_id = p.id)
    order by (select count(*) from public.apoio_vanguardistas y join public.apoios z on z.pagamento_id = y.pagamento_id
              where y.vanguardista_id = p.id and z.ambiente = a.ambiente and z.estornado_em is null
                and (z.pago_em + make_interval(months => z.meses))::date >= hoje),
             p.criado_em, p.id
    limit a.falta;
    get diagnostics q = row_count;
    total := total + q;
  end loop;
  return total;
end;
$$;

create or replace function public._alocar_ao_cadastrar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.tipo = 'vanguardista' then perform public.alocar_apoios(); end if;
  return new;
end;
$$;

drop trigger if exists alocar_apoios_novo_vanguardista on public.perfis;
create trigger alocar_apoios_novo_vanguardista
  after insert on public.perfis
  for each row execute function public._alocar_ao_cadastrar();

-- 9. Código público do selo de cada apoiador (vai no link do material) e quem chegou por ele
alter table public.apoiador_perfil add column if not exists codigo text unique
  default substr(md5(random()::text || clock_timestamp()::text), 1, 8);
update public.apoiador_perfil set codigo = substr(md5(random()::text || clock_timestamp()::text || id::text), 1, 8) where codigo is null;

create table if not exists public.selo_visitas (
  codigo  text not null,
  dia     date not null default (now() at time zone 'America/Sao_Paulo')::date,
  visitas integer not null default 1,
  primary key (codigo, dia)
);
alter table public.selo_visitas enable row level security; -- sem políticas: só pelas funções abaixo

alter table public.perfis add column if not exists indicado_por text;

-- Quem se cadastra depois de abrir o link de um selo leva o código no cadastro (metadado "ref").
-- Roda depois de ao_criar_usuario (gatilhos do mesmo evento rodam em ordem alfabética).
create or replace function public._indicacao_ao_cadastrar()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  c text := lower(trim(coalesce(new.raw_user_meta_data ->> 'ref', '')));
begin
  if c <> '' and exists (select 1 from public.apoiador_perfil where codigo = c) then
    update public.perfis set indicado_por = c where id = new.id;
  end if;
  return new;
end;
$$;

drop trigger if exists zz_indicacao_selo on auth.users;
create trigger zz_indicacao_selo
  after insert on auth.users
  for each row execute function public._indicacao_ao_cadastrar();

-- Números de um conjunto de apoios (uso interno): financeiro, vanguardistas custeados e regiões.
-- Regiões e desempenho só saem com pelo menos 5 vanguardistas; estado ou cidade só aparecem com 5 ou mais.
-- Os apoios da pessoa: mesmo CPF/CNPJ e mesmo celular ou e-mail do cadastro (ver a tabela apoios).
drop function if exists public._impacto_dos_apoios(text, text);
create or replace function public._impacto_dos_apoios(p_doc text, p_fone text, p_email text, p_ambiente text)
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  MIN_GRUPO constant integer := 5;
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
  fin jsonb;
  n integer;
  reg jsonb;
begin
  select jsonb_build_object(
    'apoios', count(*),
    'valor_total', coalesce(sum(valor), 0),
    'vanguardistas_total', coalesce(sum(vanguardistas), 0),
    'vanguardistas_ativos', coalesce(sum(vanguardistas) filter (where (pago_em + make_interval(months => meses))::date >= hoje), 0),
    'meses_vanguardista', coalesce(sum(vanguardistas * meses), 0),
    'desde', min(pago_em)
  ) into fin
  from public.apoios
  where doc = p_doc and ambiente = p_ambiente and estornado_em is null
    and (fone = p_fone or (nullif(email, '') is not null and email = lower(trim(coalesce(p_email, '')))));

  with m as (
    select distinct av.vanguardista_id as id
    from public.apoio_vanguardistas av join public.apoios ap on ap.pagamento_id = av.pagamento_id
    where ap.doc = p_doc and ap.ambiente = p_ambiente and ap.estornado_em is null
      and (ap.fone = p_fone or (nullif(ap.email, '') is not null and ap.email = lower(trim(coalesce(p_email, '')))))
  )
  select count(*) into n from m;

  if n < MIN_GRUPO then
    reg := jsonb_build_object('suficiente', false, 'minimo', MIN_GRUPO);
  else
    with m as (
      select distinct av.vanguardista_id as id
      from public.apoio_vanguardistas av join public.apoios ap on ap.pagamento_id = av.pagamento_id
      where ap.doc = p_doc and ap.ambiente = p_ambiente and ap.estornado_em is null
      and (ap.fone = p_fone or (nullif(ap.email, '') is not null and ap.email = lower(trim(coalesce(p_email, '')))))
    ),
    mp as (select p.* from public.perfis p join m on m.id = p.id),
    ufs as (select uf, count(*) as q from mp group by uf),
    cids as (select min(cidade) as cidade, uf, count(*) as q from mp group by lower(public.unaccent_safe(cidade)), uf),
    a as (select a.* from public.atividades a join m on m.id = a.vanguardista_id where a.dia > hoje - 30)
    select jsonb_build_object(
      'suficiente', true,
      'base', 'apoios',
      'vanguardistas', n,
      'regioes', coalesce((select jsonb_agg(jsonb_build_object('uf', uf, 'vanguardistas', q) order by q desc, uf) from ufs where q >= MIN_GRUPO), '[]'::jsonb),
      'cidades_lista', coalesce((select jsonb_agg(jsonb_build_object('cidade', cidade, 'uf', uf, 'vanguardistas', q) order by q desc, cidade) from cids where q >= MIN_GRUPO), '[]'::jsonb),
      'outras_regioes', exists (select 1 from ufs where q < MIN_GRUPO),
      'cidades', (select count(*) from cids),
      'ativos_30d', (select count(distinct vanguardista_id) from a),
      'simulacoes_30d', (select count(*) from a where tipo like 'simulador%'),
      'indicacoes_30d', (select count(*) from a where tipo = 'indicacao')
    ) into reg;
  end if;

  return jsonb_build_object('financeiro', fin, 'regioes', reg);
end;
$$;

-- 10. Impacto do apoiador logado, para o painel e o material. Cria o código do selo se ainda não existir.
drop function if exists public.impacto_apoiador();
create or replace function public.impacto_apoiador(p_ambiente text default 'producao')
returns jsonb
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  me public.perfis;
  cod text;
  r jsonb;
begin
  select * into me from public.perfis where id = auth.uid() and tipo = 'apoiador';
  if not found then raise exception 'apenas apoiadores'; end if;
  if p_ambiente not in ('sandbox', 'producao') then raise exception 'ambiente inválido'; end if;

  insert into public.apoiador_perfil (id) values (me.id) on conflict (id) do nothing;
  select codigo into cod from public.apoiador_perfil where id = me.id;

  r := public._impacto_dos_apoios(me.doc, me.fone, me.email, p_ambiente);
  return r || jsonb_build_object(
    'codigo', cod,
    'visitas_selo', coalesce((select sum(visitas) from public.selo_visitas where codigo = cod), 0),
    'cadastros_selo', (select count(*) from public.perfis where indicado_por = cod)
  );
end;
$$;

-- 11. Página pública do selo (sem login): marca, selos escolhidos e os números do momento.
create or replace function public.selo_publico(p_codigo text, p_ambiente text default 'producao')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  ap public.apoiador_perfil;
  me public.perfis;
begin
  if p_ambiente not in ('sandbox', 'producao') then raise exception 'ambiente inválido'; end if;
  select * into ap from public.apoiador_perfil where codigo = lower(trim(coalesce(p_codigo, '')));
  if not found then return null; end if;
  select * into me from public.perfis where id = ap.id;
  return public._impacto_dos_apoios(me.doc, me.fone, me.email, p_ambiente) || jsonb_build_object(
    'marca', coalesce(nullif(trim(ap.marca), ''), split_part(me.nome, ' ', 1)),
    'selos', to_jsonb(ap.selos)
  );
end;
$$;

-- Conta uma visita à página do selo (o navegador conta no máximo uma por dia por código).
create or replace function public.registrar_visita_selo(p_codigo text)
returns void
language plpgsql
volatile
security definer
set search_path = public
as $$
declare
  c text := lower(trim(coalesce(p_codigo, '')));
begin
  if not exists (select 1 from public.apoiador_perfil where codigo = c) then return; end if;
  insert into public.selo_visitas (codigo) values (c)
  on conflict (codigo, dia) do update set visitas = least(public.selo_visitas.visitas + 1, 100000);
end;
$$;

revoke all on function public.alocar_apoios() from public, anon, authenticated;
grant execute on function public.alocar_apoios() to service_role;
revoke all on function public._alocar_ao_cadastrar() from public, anon, authenticated;
revoke all on function public._indicacao_ao_cadastrar() from public, anon, authenticated;
revoke all on function public._impacto_dos_apoios(text, text, text, text) from public, anon, authenticated;
revoke all on function public.impacto_apoiador(text) from public, anon;
grant execute on function public.impacto_apoiador(text) to authenticated;
revoke all on function public.selo_publico(text, text) from public;
grant execute on function public.selo_publico(text, text) to anon, authenticated;
revoke all on function public.registrar_visita_selo(text) from public;
grant execute on function public.registrar_visita_selo(text) to anon, authenticated;
