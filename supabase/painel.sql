-- Portal Vanguarda: painel do apoiador (selos sociais, material de divulgação e grupos de vanguardistas)
-- Rode este arquivo no Supabase DEPOIS do schema.sql: SQL Editor > New query > colar > Run.
-- Pode rodar de novo sem perder dados (tudo é "if not exists" / "or replace").
--
-- Privacidade (LGPD): o apoiador nunca lê dados de um vanguardista. Ele só recebe números do grupo inteiro,
-- calculados aqui no banco, e só quando o grupo tem pelo menos 5 vanguardistas (constante MIN_GRUPO abaixo).
-- Dos vanguardistas, só saem região (estado e cidade), porte, tipo de negócio e faixa de faturamento, somados.
-- Nunca nome, CPF/CNPJ, celular, e-mail ou atividade de uso.

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

-- 2. Atividade dos vanguardistas: DESATIVADA (LGPD, minimização de dados).
--    O painel mostra dos vanguardistas só faturamento, região, tipo de negócio e porte, somados.
--    O registro de uso dos simuladores deixou de ser feito e a tabela antiga é apagada.
drop table if exists public.atividades;

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

-- 3b. Perfil somado de um conjunto de vanguardistas (uso interno): porte, tipo de negócio e faixa de
--     faturamento. Só sai uma faixa com 5 ou mais vanguardistas; as menores são somadas em "outros",
--     que também fica com 0 ou com pelo menos 5.
create or replace function public._perfil_somado(p_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
  with mp as (select p.porte_negocio, p.ramo, p.faturamento from public.perfis p where p.id = any(p_ids)),
  campos as (
    select 'portes' as campo, coalesce(porte_negocio, 'nao_informado') as k from mp
    union all select 'ramos', coalesce(ramo, 'nao_informado') from mp
    union all select 'faturamento', coalesce(faturamento, 'nao_informado') from mp
  ),
  cont as (select campo, k, count(*) as q from campos group by campo, k),
  -- faixas pequenas (menos de 5) vão para "outros". Se "outros" ficar entre 1 e 4, a menor faixa grande
  -- também vai para lá, para que ninguém descubra um grupo pequeno subtraindo do total.
  base as (
    select c.*, sum(case when q < 5 then q else 0 end) over (partition by campo) as pequeno,
           row_number() over (partition by campo, (q >= 5) order by q, k) as ordem
    from cont c
  ),
  marcado as (
    select campo, k, q, (q < 5 or (pequeno between 1 and 4 and q >= 5 and ordem = 1)) as vai_para_outros from base
  ),
  por_campo as (
    select campo,
           coalesce(jsonb_agg(jsonb_build_object('k', k, 'q', q) order by q desc, k) filter (where not vai_para_outros), '[]'::jsonb) as faixas,
           coalesce(sum(q) filter (where vai_para_outros), 0) as outros
    from marcado group by campo
  )
  select coalesce(jsonb_object_agg(campo, jsonb_build_object('faixas', faixas, 'outros', outros)), '{}'::jsonb)
  from por_campo;
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

-- 6. Perfil somado de um grupo do próprio apoiador: quantos vanguardistas e a distribuição por porte,
--    tipo de negócio e faixa de faturamento. Nada por pessoa e nada de uso ou atividade.
drop function if exists public.painel_grupo(uuid);
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
begin
  select * into g from public.grupos where id = p_grupo and apoiador_id = auth.uid();
  if not found then raise exception 'grupo não encontrado'; end if;

  n := public._grupo_seguro(g.uf, g.cidade, g.tipo_doc, MIN_GRUPO);
  if n is null then
    return jsonb_build_object('suficiente', false, 'minimo', MIN_GRUPO);
  end if;

  return jsonb_build_object('suficiente', true, 'vanguardistas', n, 'perfil',
    public._perfil_somado(array(select id from public._membros_grupo(g.uf, g.cidade, g.tipo_doc))));
end;
$$;

revoke all on function public._membros_grupo(text, text, text) from public, anon, authenticated;
revoke all on function public._grupo_seguro(text, text, text, integer) from public, anon, authenticated;
revoke all on function public.contar_grupo(text, text, text) from public, anon;
revoke all on function public.painel_grupo(uuid) from public, anon;
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
    mp as (select p.cidade, p.uf from public.perfis p join m on m.id = p.id),
    ufs as (select uf, count(*) as q from mp group by uf),
    cids as (select min(cidade) as cidade, uf, count(*) as q from mp group by lower(public.unaccent_safe(cidade)), uf)
    select jsonb_build_object(
      'suficiente', true,
      'base', 'apoios',
      'vanguardistas', n,
      'regioes', coalesce((select jsonb_agg(jsonb_build_object('uf', uf, 'vanguardistas', q) order by q desc, uf) from ufs where q >= MIN_GRUPO), '[]'::jsonb),
      'cidades_lista', coalesce((select jsonb_agg(jsonb_build_object('cidade', cidade, 'uf', uf, 'vanguardistas', q) order by q desc, cidade) from cids where q >= MIN_GRUPO), '[]'::jsonb),
      'outras_regioes', exists (select 1 from ufs where q < MIN_GRUPO),
      'perfil', public._perfil_somado(array(select id from m))
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
  r jsonb;
  selos text[];
begin
  if p_ambiente not in ('sandbox', 'producao') then raise exception 'ambiente inválido'; end if;
  select * into ap from public.apoiador_perfil where codigo = lower(trim(coalesce(p_codigo, '')));
  if not found then return null; end if;
  select * into me from public.perfis where id = ap.id;
  r := public._impacto_dos_apoios(me.doc, me.fone, me.email, p_ambiente);
  selos := coalesce(ap.selos, '{}');
  -- Nenhum selo é livre: sem pelo menos 1 apoio pago e não estornado confirmado no Asaas, a página pública não mostra
  -- nenhum selo. A escolha continua salva em apoiador_perfil e volta a aparecer quando o pagamento for regularizado.
  if coalesce((r #>> '{financeiro,apoios}')::integer, 0) < 1 then
    selos := '{}';
  end if;
  -- Powered by só aparece para quem pagou pelo menos 180 meses de uso (vanguardistas x meses, somando os apoios)
  if coalesce((r #>> '{financeiro,meses_vanguardista}')::integer, 0) < 180 then
    selos := array_remove(selos, 'powered');
  end if;
  return r || jsonb_build_object(
    'marca', coalesce(nullif(trim(ap.marca), ''), split_part(me.nome, ' ', 1)),
    'selos', to_jsonb(selos)
  );
end;
$$;

-- 12. Validação dos selos escolhidos: o banco confere os apoios do Asaas antes de aceitar um selo novo.
--     Selo novo sem pelo menos 1 apoio pago e não estornado (em qualquer ambiente) é descartado; Powered by novo
--     também é descartado sem 180 meses de uso apadrinhados. Selos que já estavam salvos ficam salvos (a escolha
--     persiste se o apoio for estornado); a exibição pública é filtrada em selo_publico.
create or replace function public._validar_selos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  me public.perfis;
  novos text[];
  amb text;
  f jsonb;
  n_apoios integer := 0;
  n_meses integer := 0;
begin
  novos := array(
    select unnest(coalesce(new.selos, '{}'))
    except
    select unnest(case when tg_op = 'UPDATE' then coalesce(old.selos, '{}') else '{}'::text[] end)
  );
  if coalesce(array_length(novos, 1), 0) = 0 then return new; end if;
  select * into me from public.perfis where id = new.id;
  if found then
    foreach amb in array array['producao', 'sandbox'] loop
      f := public._impacto_dos_apoios(me.doc, me.fone, me.email, amb) -> 'financeiro';
      n_apoios := greatest(n_apoios, coalesce((f ->> 'apoios')::integer, 0));
      n_meses := greatest(n_meses, coalesce((f ->> 'meses_vanguardista')::integer, 0));
    end loop;
  end if;
  if n_apoios < 1 then
    new.selos := array(select x from unnest(new.selos) x where not (x = any(novos)));
  elsif n_meses < 180 and 'powered' = any(novos) then
    new.selos := array_remove(new.selos, 'powered');
  end if;
  return new;
end;
$$;

drop trigger if exists validar_selos on public.apoiador_perfil;
create trigger validar_selos
  before insert or update of selos on public.apoiador_perfil
  for each row execute function public._validar_selos();

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
revoke all on function public._validar_selos() from public, anon, authenticated;
revoke all on function public._impacto_dos_apoios(text, text, text, text) from public, anon, authenticated;
revoke all on function public._perfil_somado(uuid[]) from public, anon, authenticated;
revoke all on function public.impacto_apoiador(text) from public, anon;
grant execute on function public.impacto_apoiador(text) to authenticated;
revoke all on function public.selo_publico(text, text) from public;
grant execute on function public.selo_publico(text, text) to anon, authenticated;
revoke all on function public.registrar_visita_selo(text) from public;
grant execute on function public.registrar_visita_selo(text) to anon, authenticated;

-- 12b. Excluir a própria conta (botão "Excluir minha conta" no site). Só age sobre a conta logada (auth.uid()):
--      apaga os apoios dela (mesmo CPF/CNPJ e mesmo celular ou e-mail, a mesma regra do painel), as visitas do
--      selo dela e o usuário em auth.users; perfil, perfil de apoiador, grupos e vínculos com apoios saem em
--      cascata. Depois redistribui as vagas de apoios que ficaram sem vanguardista. Cobranças e notas fiscais
--      já emitidas continuam no Asaas (registro fiscal), fora do banco do portal.
create or replace function public._excluir_conta(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  me public.perfis%rowtype;
  cod text;
begin
  if p_id is null then raise exception 'conta não informada'; end if;
  if exists (select 1 from public.admins a join auth.users u on lower(u.email) = a.email where u.id = p_id) then
    raise exception 'a conta de administrador não é excluída por aqui' using errcode = '42501';
  end if;
  select * into me from public.perfis where id = p_id;
  if found and nullif(me.doc, '') is not null then
    delete from public.apoios
    where doc = me.doc
      and (fone = me.fone or (nullif(email, '') is not null and email = lower(trim(coalesce(me.email, '')))));
  end if;
  select codigo into cod from public.apoiador_perfil where id = p_id;
  if cod is not null then
    delete from public.selo_visitas where codigo = cod;
  end if;
  delete from auth.users where id = p_id;
  perform public.alocar_apoios();
  return true;
end;
$$;

create or replace function public.excluir_minha_conta()
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  if auth.uid() is null then
    raise exception 'sem login' using errcode = '42501';
  end if;
  return public._excluir_conta(auth.uid());
end;
$$;

revoke all on function public._excluir_conta(uuid) from public, anon, authenticated;
revoke all on function public.excluir_minha_conta() from public, anon;
grant execute on function public.excluir_minha_conta() to authenticated;

-- 13. Permissões explícitas da Data API (versão atual do Supabase, Postgres 17).
--     Projetos novos podem vir com "expor tabelas novas automaticamente" desligado; aí as tabelas não recebem
--     permissão nenhuma para anon/authenticated e o painel quebra. Nos projetos antigos, as permissões padrão dão
--     tudo a todos (o RLS é que segura). Aqui cada papel recebe só o que o site usa, nos dois casos.
revoke all on public.apoiador_perfil from anon, authenticated;
grant select, insert, update on public.apoiador_perfil to authenticated;
revoke all on public.grupos from anon, authenticated;
grant select, insert, delete on public.grupos to authenticated;
-- Só o webhook do Asaas (chave de serviço) e as funções do banco mexem nestas:
revoke all on public.apoios, public.apoio_vanguardistas, public.selo_visitas from anon, authenticated;
grant all on public.apoios, public.apoio_vanguardistas, public.selo_visitas to service_role;
