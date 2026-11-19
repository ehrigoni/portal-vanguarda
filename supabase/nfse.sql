-- Portal Vanguarda: notas fiscais de serviço (NFS-e) emitidas pelo Asaas
-- Rode este arquivo uma vez no Supabase, depois do schema.sql: SQL Editor > New query > colar > Run.
-- Só a função asaas-webhook (com a service role) escreve aqui. Ninguém lê pelo site.

-- 1. Uma linha por pagamento do Asaas que gerou (ou vai gerar) nota
create table if not exists public.notas_fiscais (
  pagamento_id     text primary key,          -- id da cobrança no Asaas (pay_...)
  nota_id          text unique,               -- id da nota no Asaas (inv_...)
  cliente_id       text,                      -- id do cliente no Asaas (cus_...)
  servico          text not null,             -- código de tributação nacional usado (ex.: 01.09.02)
  valor            numeric(12, 2) not null,
  status           text not null default 'AGENDANDO',
  numero           text,                      -- número da NFS-e depois de autorizada
  codigo_verificacao text,
  pdf_url          text,
  xml_url          text,
  erro             text,
  criado_em        timestamptz not null default now(),
  atualizado_em    timestamptz not null default now()
);

alter table public.notas_fiscais enable row level security;
-- Sem políticas: só a service role (usada pela função) lê e escreve.

-- 2. Eventos de webhook já processados (o Asaas pode reenviar o mesmo evento)
create table if not exists public.asaas_eventos (
  id           text primary key,              -- id do evento enviado pelo Asaas
  evento       text not null,
  recebido_em  timestamptz not null default now()
);

alter table public.asaas_eventos enable row level security;
