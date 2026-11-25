-- Portal Vanguarda: aba Administrador (simuladores, selos, impacto, apoiadores e usuários)
-- Rode este arquivo no Supabase DEPOIS do schema.sql e do painel.sql: SQL Editor > New query > colar > Run.
-- Pode rodar de novo sem perder dados.
--
-- Acesso: toda função aqui começa conferindo public.is_admin() (schema.sql), que olha a tabela admins.
-- A tela só esconde a aba; quem barra é o banco. Nenhuma tabela nova fica aberta para escrita pelo site.

create or replace function public._exigir_admin()
returns void
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  if not public.is_admin() then
    raise exception 'apenas administradores' using errcode = '42501';
  end if;
end;
$$;

-- 1. Configuração do site (por enquanto, quais simuladores aparecem). Todos leem; só o administrador grava,
--    pela função admin_config_salvar.
create table if not exists public.config_site (
  chave         text primary key check (chave ~ '^[a-z_]{1,40}$'),
  valor         jsonb not null,
  atualizado_em timestamptz not null default now()
);
alter table public.config_site enable row level security;
drop policy if exists "todos leem a configuracao" on public.config_site;
create policy "todos leem a configuracao" on public.config_site for select using (true);
revoke all on public.config_site from anon, authenticated;
grant select on public.config_site to anon, authenticated;

create or replace function public.admin_config_salvar(p_chave text, p_valor jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._exigir_admin();
  if p_chave not in ('simuladores') then raise exception 'configuração desconhecida'; end if;
  if jsonb_typeof(p_valor) <> 'object' then raise exception 'valor inválido'; end if;
  insert into public.config_site (chave, valor) values (p_chave, p_valor)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  return p_valor;
end;
$$;

-- 2. Impacto do portal inteiro, num ambiente (producao ou sandbox).
create or replace function public.admin_resumo(p_ambiente text default 'producao')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  hoje date := (now() at time zone 'America/Sao_Paulo')::date;
begin
  perform public._exigir_admin();
  if p_ambiente not in ('sandbox', 'producao') then raise exception 'ambiente inválido'; end if;
  return jsonb_build_object(
    'vanguardistas', (select count(*) from public.perfis where tipo = 'vanguardista'),
    'apoiadores', (select count(*) from public.perfis where tipo = 'apoiador'),
    'cadastros_30d', (select count(*) from public.perfis where criado_em >= now() - interval '30 days'),
    'apoios', (select count(*) from public.apoios where ambiente = p_ambiente and estornado_em is null),
    'estornados', (select count(*) from public.apoios where ambiente = p_ambiente and estornado_em is not null),
    'valor_total', (select coalesce(sum(valor), 0) from public.apoios where ambiente = p_ambiente and estornado_em is null),
    'vagas_total', (select coalesce(sum(vanguardistas), 0) from public.apoios where ambiente = p_ambiente and estornado_em is null),
    'vagas_vigentes', (select coalesce(sum(vanguardistas), 0) from public.apoios where ambiente = p_ambiente and estornado_em is null
                        and (pago_em + make_interval(months => meses))::date >= hoje),
    'vagas_alocadas', (select count(*) from public.apoio_vanguardistas av join public.apoios a on a.pagamento_id = av.pagamento_id
                        where a.ambiente = p_ambiente and a.estornado_em is null),
    'apadrinhados', (select count(distinct av.vanguardista_id) from public.apoio_vanguardistas av join public.apoios a on a.pagamento_id = av.pagamento_id
                      where a.ambiente = p_ambiente and a.estornado_em is null and (a.pago_em + make_interval(months => a.meses))::date >= hoje),
    'meses_vanguardista', (select coalesce(sum(vanguardistas * meses), 0) from public.apoios where ambiente = p_ambiente and estornado_em is null),
    'visitas_selo', (select coalesce(sum(visitas), 0) from public.selo_visitas),
    'cadastros_selo', (select count(*) from public.perfis where indicado_por is not null),
    'por_uf', coalesce((select jsonb_agg(jsonb_build_object('uf', uf, 'vanguardistas', q) order by q desc, uf)
                        from (select uf, count(*) q from public.perfis where tipo = 'vanguardista' group by uf) x), '[]'::jsonb)
  );
end;
$$;

-- 3. Usuários (vanguardistas e apoiadores): lista com busca, edição e exclusão.
create or replace function public.admin_usuarios(p_busca text default '', p_tipo text default '')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  b text := lower(trim(coalesce(p_busca, '')));
  d text := regexp_replace(coalesce(p_busca, ''), '[^0-9]', '', 'g');
begin
  perform public._exigir_admin();
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.criado_em desc)
    from (
      select p.id, p.tipo, p.nome, p.fone, p.email, p.doc, p.cep, p.rua, p.bairro, p.numero, p.complemento,
             p.cidade, p.uf, p.porte_negocio, p.ramo, p.faturamento, p.indicado_por, p.criado_em
      from public.perfis p
      where (coalesce(p_tipo, '') = '' or p.tipo = p_tipo)
        and (b = '' or lower(p.nome) like '%' || b || '%' or lower(coalesce(p.email, '')) like '%' || b || '%'
             or lower(p.cidade) like '%' || b || '%' or (d <> '' and (p.fone like '%' || d || '%' or p.doc like '%' || d || '%')))
      order by p.criado_em desc
      limit 500
    ) x), '[]'::jsonb);
end;
$$;

create or replace function public.admin_salvar_usuario(p_id uuid, p_dados jsonb)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
  t text;
begin
  perform public._exigir_admin();
  if not exists (select 1 from public.perfis where id = p_id) then raise exception 'usuário não encontrado'; end if;
  t := p_dados ->> 'tipo';
  update public.perfis set
    tipo        = coalesce(nullif(t, ''), tipo),
    nome        = coalesce(nullif(trim(p_dados ->> 'nome'), ''), nome),
    fone        = coalesce(nullif(regexp_replace(coalesce(p_dados ->> 'fone', ''), '[^0-9]', '', 'g'), ''), fone),
    email       = case when p_dados ? 'email' then nullif(lower(trim(coalesce(p_dados ->> 'email', ''))), '') else email end,
    doc         = coalesce(nullif(regexp_replace(coalesce(p_dados ->> 'doc', ''), '[^0-9]', '', 'g'), ''), doc),
    cep         = case when p_dados ? 'cep' then nullif(regexp_replace(coalesce(p_dados ->> 'cep', ''), '[^0-9]', '', 'g'), '') else cep end,
    rua         = case when p_dados ? 'rua' then nullif(left(trim(coalesce(p_dados ->> 'rua', '')), 160), '') else rua end,
    bairro      = case when p_dados ? 'bairro' then nullif(left(trim(coalesce(p_dados ->> 'bairro', '')), 80), '') else bairro end,
    numero      = case when p_dados ? 'numero' then nullif(left(trim(coalesce(p_dados ->> 'numero', '')), 10), '') else numero end,
    complemento = case when p_dados ? 'complemento' then nullif(left(trim(coalesce(p_dados ->> 'complemento', '')), 60), '') else complemento end,
    cidade      = coalesce(nullif(trim(p_dados ->> 'cidade'), ''), cidade),
    uf          = coalesce(nullif(upper(trim(p_dados ->> 'uf')), ''), uf)
  where id = p_id;
  -- quem vira vanguardista pode completar apoios que estavam sem vaga
  if t = 'vanguardista' then perform public.alocar_apoios(); end if;
  return true;
end;
$$;

create or replace function public.admin_excluir_usuario(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._exigir_admin();
  return public._excluir_conta(p_id);
end;
$$;

-- 4. Apoiadores e apoios.
create or replace function public.admin_apoiadores(p_ambiente text default 'producao')
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._exigir_admin();
  if p_ambiente not in ('sandbox', 'producao') then raise exception 'ambiente inválido'; end if;
  return jsonb_build_object(
    'apoiadores', coalesce((
      select jsonb_agg(to_jsonb(x) order by x.valor desc, x.nome)
      from (
        select p.id, p.nome, p.fone, p.email, p.doc, p.cidade, p.uf, p.criado_em, ap.marca, ap.codigo, ap.selos,
               coalesce(f.apoios, 0) as apoios, coalesce(f.valor, 0) as valor, coalesce(f.vagas, 0) as vagas
        from public.perfis p
        left join public.apoiador_perfil ap on ap.id = p.id
        left join lateral (
          select count(*) as apoios, sum(a.valor) as valor, sum(a.vanguardistas) as vagas
          from public.apoios a
          where a.doc = p.doc and a.ambiente = p_ambiente and a.estornado_em is null
            and (a.fone = p.fone or (nullif(a.email, '') is not null and a.email = lower(trim(coalesce(p.email, '')))))
        ) f on true
        where p.tipo = 'apoiador'
      ) x), '[]'::jsonb),
    'apoios', coalesce((
      select jsonb_agg(to_jsonb(y) order by y.pago_em desc, y.criado_em desc)
      from (
        select a.pagamento_id, a.doc, a.fone, a.email, a.vanguardistas, a.meses, a.valor, a.pago_em, a.estornado_em, a.criado_em,
               (select count(*) from public.apoio_vanguardistas av where av.pagamento_id = a.pagamento_id) as alocados,
               (select p.nome from public.perfis p where p.doc = a.doc
                  and (p.fone = a.fone or (nullif(a.email, '') is not null and p.email = a.email)) limit 1) as conta
        from public.apoios a
        where a.ambiente = p_ambiente
        order by a.pago_em desc
        limit 500
      ) y), '[]'::jsonb)
  );
end;
$$;

create or replace function public.admin_alocar()
returns integer
language plpgsql
security definer
set search_path = public
as $$
begin
  perform public._exigir_admin();
  return public.alocar_apoios();
end;
$$;

-- 5. Selos: código, marca, selos escolhidos, visitas e cadastros vindos do link de cada apoiador.
create or replace function public.admin_selos()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
begin
  perform public._exigir_admin();
  return coalesce((
    select jsonb_agg(to_jsonb(x) order by x.visitas desc, x.nome)
    from (
      select ap.id, p.nome, ap.marca, ap.codigo, ap.selos, ap.atualizado_em,
             coalesce((select sum(v.visitas) from public.selo_visitas v where v.codigo = ap.codigo), 0) as visitas,
             (select count(*) from public.perfis q where q.indicado_por = ap.codigo) as cadastros
      from public.apoiador_perfil ap join public.perfis p on p.id = ap.id
    ) x), '[]'::jsonb);
end;
$$;

-- Edita marca e selos de um apoiador. Selos novos passam pela mesma regra do painel (gatilho validar_selos).
create or replace function public.admin_salvar_selos(p_id uuid, p_marca text, p_selos text[])
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  r public.apoiador_perfil;
begin
  perform public._exigir_admin();
  update public.apoiador_perfil
     set marca = nullif(left(trim(coalesce(p_marca, '')), 80), ''),
         selos = coalesce(p_selos, '{}'),
         atualizado_em = now()
   where id = p_id
  returning * into r;
  if not found then raise exception 'apoiador sem perfil de selos'; end if;
  return jsonb_build_object('marca', r.marca, 'selos', r.selos);
end;
$$;

revoke all on function public._exigir_admin() from public, anon, authenticated;
do $$
declare f text;
begin
  foreach f in array array[
    'admin_config_salvar(text, jsonb)', 'admin_resumo(text)', 'admin_usuarios(text, text)',
    'admin_salvar_usuario(uuid, jsonb)', 'admin_excluir_usuario(uuid)', 'admin_apoiadores(text)',
    'admin_alocar()', 'admin_selos()', 'admin_salvar_selos(uuid, text, text[])'] loop
    execute format('revoke all on function public.%s from public, anon', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end;
$$;
