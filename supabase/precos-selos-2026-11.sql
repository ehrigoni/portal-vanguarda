-- Portal Vanguarda: preço e períodos do apoio, e requisitos dos selos, configuráveis na aba Administrador
-- Rode UMA vez no Supabase, DEPOIS do schema.sql, do painel.sql, do admin.sql e do fluxo-2026-11.sql:
-- SQL Editor > New query > colar este arquivo inteiro > Run. Pode rodar de novo: nada é apagado e a
-- configuração já salva no painel não é sobrescrita.
--
-- O que muda:
-- 1. config_site ganha duas chaves, editadas só pelo administrador (admin_config_salvar):
--    - apoio: valor unitário do apadrinhamento (R$ por vanguardista, a cada mês), lista de períodos
--      oferecidos (em meses) e se o Apoiar mostra "Outro" e "Todo mês (assinatura)". Começa com R$ 156 e
--      períodos de 1, 6 e 12 meses. O servidor de cobrança (api/asaas/cobranca.js) lê este valor: o total
--      cobrado é valor unitário x apadrinhados x meses, calculado no servidor.
--    - selos: requisitos de cada selo (valor total investido, mínimo de vanguardistas apadrinhados,
--      mínimo de convidados que se cadastraram pelo link do selo e meses de uso apadrinhados), mais nome,
--      ícone (sigla) e tipo de meta, opcionais. Começa com o Powered by em 180 meses, como hoje.
-- 2. Todo selo continua exigindo pelo menos 1 apoio pago e não estornado. Os requisitos se somam a isso.
-- 3. A função _selos_liberados confere os requisitos no banco. O gatilho validar_selos só aceita um selo novo
--    que cumpra os requisitos, e a página pública do selo (selo_publico) só mostra os selos que continuam
--    cumprindo. A escolha salva fica guardada e volta a aparecer quando o requisito for cumprido de novo.

-- 1. Configuração inicial (não sobrescreve o que já foi salvo)
insert into public.config_site (chave, valor) values
  ('apoio', '{"valor_unitario": 156, "periodos": [1, 6, 12], "outro": true, "assinatura": true}'::jsonb),
  ('selos', '{"powered": {"meses": 180}}'::jsonb)
on conflict (chave) do nothing;

-- 2. Gravação pelo administrador, com validação de cada chave
create or replace function public.admin_config_salvar(p_chave text, p_valor jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  k text;
  v jsonb;
  c text;
  per jsonb;
begin
  perform public._exigir_admin();
  if p_chave not in ('simuladores', 'apoio', 'selos') then raise exception 'configuração desconhecida'; end if;
  if jsonb_typeof(p_valor) <> 'object' then raise exception 'valor inválido'; end if;

  if p_chave = 'apoio' then
    if jsonb_typeof(p_valor -> 'valor_unitario') <> 'number'
       or (p_valor ->> 'valor_unitario')::numeric <= 0 or (p_valor ->> 'valor_unitario')::numeric > 100000 then
      raise exception 'valor unitário inválido';
    end if;
    per := p_valor -> 'periodos';
    if jsonb_typeof(per) <> 'array' or jsonb_array_length(per) < 1 or jsonb_array_length(per) > 12 then
      raise exception 'informe de 1 a 12 períodos';
    end if;
    for v in select * from jsonb_array_elements(per) loop
      if jsonb_typeof(v) <> 'number' or (v #>> '{}')::numeric <> trunc((v #>> '{}')::numeric)
         or (v #>> '{}')::numeric < 1 or (v #>> '{}')::numeric > 120 then
        raise exception 'cada período deve ser um número inteiro de meses, de 1 a 120';
      end if;
    end loop;
    if (select count(distinct x) from jsonb_array_elements_text(per) x) <> jsonb_array_length(per) then
      raise exception 'períodos repetidos';
    end if;
    p_valor := jsonb_build_object(
      'valor_unitario', round((p_valor ->> 'valor_unitario')::numeric, 2),
      'periodos', (select jsonb_agg(x::int order by x::int) from jsonb_array_elements_text(per) x),
      'outro', coalesce((p_valor ->> 'outro')::boolean, true),
      'assinatura', coalesce((p_valor ->> 'assinatura')::boolean, true));
  elsif p_chave = 'selos' then
    for k, v in select * from jsonb_each(p_valor) loop
      if k !~ '^[a-z0-9]{1,20}$' or jsonb_typeof(v) <> 'object' then raise exception 'selo inválido: %', k; end if;
      foreach c in array array['valor', 'vanguardistas', 'convidados', 'meses'] loop
        if v ? c and (jsonb_typeof(v -> c) <> 'number' or (v ->> c)::numeric < 0 or (v ->> c)::numeric > 10000000) then
          raise exception 'requisito inválido em %: %', k, c;
        end if;
      end loop;
      if (v ? 'nome' and length(coalesce(v ->> 'nome', '')) > 80)
         or (v ? 'sigla' and length(coalesce(v ->> 'sigla', '')) > 6)
         or (v ? 'cat' and length(coalesce(v ->> 'cat', '')) > 40) then
        raise exception 'texto longo demais em %', k;
      end if;
    end loop;
  end if;

  insert into public.config_site (chave, valor) values (p_chave, p_valor)
  on conflict (chave) do update set valor = excluded.valor, atualizado_em = now();
  return p_valor;
end;
$$;
revoke all on function public.admin_config_salvar(text, jsonb) from public, anon;
grant execute on function public.admin_config_salvar(text, jsonb) to authenticated;

-- 3. Selos que um apoiador cumpre num ambiente (uso interno)
create or replace function public._selos_liberados(p_id uuid, p_ambiente text)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
  me public.perfis;
  f jsonb;
  cfg jsonb;
  r jsonb;
  cod text;
  conv integer := 0;
  sid text;
  ok text[] := '{}';
begin
  select * into me from public.perfis where id = p_id;
  if not found then return ok; end if;
  f := public._impacto_dos_apoios(me.doc, me.fone, me.email, p_ambiente) -> 'financeiro';
  if coalesce((f ->> 'apoios')::integer, 0) < 1 then return ok; end if;  -- todo selo exige 1 apoio pago
  select codigo into cod from public.apoiador_perfil where apoiador_perfil.id = p_id;
  if cod is not null then select count(*) into conv from public.perfis where indicado_por = cod; end if;
  select valor into cfg from public.config_site where chave = 'selos';
  cfg := coalesce(cfg, '{}'::jsonb);
  foreach sid in array array(
    select unnest(array['madrinha', 'educacao', 'periferia', 'ods8', 'ods4', 'ods10', 'techbem', 'powered'])
    union select jsonb_object_keys(cfg)) loop
    r := coalesce(cfg -> sid, '{}'::jsonb);
    if sid = 'powered' and not (r ? 'meses') then r := r || '{"meses": 180}'::jsonb; end if;
    if coalesce((f ->> 'valor_total')::numeric, 0) >= coalesce((r ->> 'valor')::numeric, 0)
       and coalesce((f ->> 'vanguardistas_total')::numeric, 0) >= coalesce((r ->> 'vanguardistas')::numeric, 0)
       and coalesce((f ->> 'meses_vanguardista')::numeric, 0) >= coalesce((r ->> 'meses')::numeric, 0)
       and conv >= coalesce((r ->> 'convidados')::numeric, 0) then
      ok := ok || sid;
    end if;
  end loop;
  return ok;
end;
$$;
revoke all on function public._selos_liberados(uuid, text) from public, anon, authenticated;

-- 4. Validação dos selos escolhidos: selo novo só entra se cumprir os requisitos (em qualquer ambiente)
create or replace function public._validar_selos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  novos text[];
  lib text[];
begin
  novos := array(
    select unnest(coalesce(new.selos, '{}'))
    except
    select unnest(case when tg_op = 'UPDATE' then coalesce(old.selos, '{}') else '{}'::text[] end)
  );
  if coalesce(array_length(novos, 1), 0) = 0 then return new; end if;
  lib := public._selos_liberados(new.id, 'producao') || public._selos_liberados(new.id, 'sandbox');
  new.selos := array(select x from unnest(new.selos) x where not (x = any(novos)) or x = any(lib));
  return new;
end;
$$;
revoke all on function public._validar_selos() from public, anon, authenticated;

-- 5. Página pública do selo: só os selos que continuam cumprindo os requisitos
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
  lib text[];
begin
  if p_ambiente not in ('sandbox', 'producao') then raise exception 'ambiente inválido'; end if;
  select * into ap from public.apoiador_perfil where codigo = lower(trim(coalesce(p_codigo, '')));
  if not found then return null; end if;
  select * into me from public.perfis where id = ap.id;
  r := public._impacto_dos_apoios(me.doc, me.fone, me.email, p_ambiente);
  lib := public._selos_liberados(ap.id, p_ambiente);
  return r || jsonb_build_object(
    'marca', coalesce(nullif(trim(ap.marca), ''), split_part(me.nome, ' ', 1)),
    'selos', to_jsonb(array(select x from unnest(coalesce(ap.selos, '{}')) x where x = any(lib)))
  );
end;
$$;
revoke all on function public.selo_publico(text, text) from public;
grant execute on function public.selo_publico(text, text) to anon, authenticated;
