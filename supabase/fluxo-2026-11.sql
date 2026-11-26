-- Portal Vanguarda: novo fluxo do site (Minha conta, cadastro mais curto)
-- Rode UMA vez no Supabase: SQL Editor > New query > colar este arquivo inteiro > Run.
-- Pode rodar de novo sem problema: nada é apagado.
--
-- O que muda:
-- 1. CPF/CNPJ fica opcional no cadastro do vanguardista. Para apoiador continua obrigatório
--    (o formulário Apoiar e o servidor de cobrança também exigem CPF/CNPJ e endereço na hora do apoio).
-- 2. O cadastro grava CPF/CNPJ vazio como nulo, em vez de recusar a conta.
-- 3. Porte e tipo de negócio passam a ficar só em perfis (porte_negocio, ramo). Copia o que
--    os apoiadores já tinham preenchido no painel (apoiador_perfil) para perfis, sem sobrescrever.
-- 4. Grupos de vanguardistas deixam de filtrar por CPF/CNPJ: com o documento opcional, esse filtro
--    deixaria descobrir, por subtração, um grupo pequeno de pessoas sem documento (LGPD).

-- 1. CPF/CNPJ opcional, menos para apoiador
alter table public.perfis alter column doc drop not null;
update public.perfis set doc = null where doc = '';
do $$
begin
  if not exists (select 1 from pg_constraint where conname = 'perfis_doc_apoiador' and conrelid = 'public.perfis'::regclass) then
    alter table public.perfis add constraint perfis_doc_apoiador check (tipo <> 'apoiador' or doc is not null);
  end if;
end $$;

-- 2. Cadastro: CPF/CNPJ vazio vira nulo
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
    nullif(regexp_replace(coalesce(new.raw_user_meta_data ->> 'doc', ''), '[^0-9]', '', 'g'), ''),
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
revoke all on function public.criar_perfil() from public, anon, authenticated;

-- 3. Porte e tipo de negócio num lugar só (perfis)
update public.perfis p set porte_negocio = ap.porte
from public.apoiador_perfil ap
where ap.id = p.id and p.porte_negocio is null and ap.porte in ('autonomo', 'mei', 'me', 'epp', 'media');

update public.perfis p set ramo = ap.setor
from public.apoiador_perfil ap
where ap.id = p.id and p.ramo is null
  and ap.setor in ('comercio', 'alimentacao', 'servicos', 'tecnologia', 'industria', 'educacao', 'saude', 'financas', 'construcao', 'outro');

-- 4. Grupos só por estado e cidade (o parâmetro p_tipo_doc continua na assinatura, mas é ignorado)
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
         or lower(unaccent_safe(p.cidade)) = lower(unaccent_safe(trim(p_cidade))));
$$;
revoke all on function public._membros_grupo(text, text, text) from public, anon, authenticated;
