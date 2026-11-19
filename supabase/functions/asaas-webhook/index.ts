// Portal Vanguarda: webhook do Asaas que emite a NFS-e de cada pagamento.
//
// Fluxo:
// 1. O Asaas avisa que um pagamento foi confirmado (PAYMENT_CONFIRMED ou PAYMENT_RECEIVED).
// 2. Esta função agenda a nota no Asaas (POST /v3/invoices) para aquele pagamento.
// 3. O Asaas transmite a nota ao Sistema Nacional da NFS-e, que é o que Porto Alegre usa.
//    Não existe um envio à parte para a prefeitura: nota autorizada já está registrada lá.
// 4. O Asaas avisa o andamento (INVOICE_SYNCHRONIZED, INVOICE_AUTHORIZED, INVOICE_ERROR...)
//    e a função guarda número, PDF e XML na tabela notas_fiscais.
//
// Segredos (supabase secrets set ...):
//   ASAAS_API_KEY        chave de API do Asaas ($aact_...)
//   ASAAS_WEBHOOK_TOKEN  o mesmo token informado ao criar o webhook no Asaas
//   ASAAS_API_URL        opcional; padrão https://api.asaas.com/v3 (sandbox: https://api-sandbox.asaas.com/v3)
//   NFSE_ISS_APOIO       opcional; alíquota de ISS do plano de apoio, padrão 2
//   NFSE_ISS_COTA        opcional; alíquota de ISS da cota de empresa, padrão 5
//   NFSE_ISS_CURSO       opcional; alíquota de ISS de cursos, padrão 5
//
// SUPABASE_URL e SUPABASE_SERVICE_ROLE_KEY já existem em toda Edge Function.

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

const API = Deno.env.get("ASAAS_API_URL") ?? "https://api.asaas.com/v3";
const API_KEY = Deno.env.get("ASAAS_API_KEY") ?? "";
const WEBHOOK_TOKEN = Deno.env.get("ASAAS_WEBHOOK_TOKEN") ?? "";

const db = createClient(
  Deno.env.get("SUPABASE_URL")!,
  Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!,
  { auth: { persistSession: false } },
);

// Serviço de cada tipo de venda. O tipo vem do externalReference da cobrança,
// no formato "<tipo>:<qualquer coisa>", por exemplo "apoio:plano-mensal" ou "cota:empresa-x".
// Sem externalReference, a cobrança é tratada como plano de apoio.
type Servico = { codigo: string; nome: string; descricao: string; iss: number };

const SERVICOS: Record<string, Servico> = {
  apoio: {
    codigo: "01.09.02",
    nome: "Disponibilização, sem cessão definitiva, de conteúdos de vídeo, imagem e texto por meio da internet",
    descricao: "Plano de apoio ao Portal Vanguarda: acesso a conteúdos, simuladores e comunidade pela internet.",
    iss: Number(Deno.env.get("NFSE_ISS_APOIO") ?? 2),
  },
  cota: {
    codigo: "17.25.01",
    nome: "Inserção de textos, desenhos e outros materiais de propaganda e publicidade, em qualquer meio",
    descricao: "Cota de empresa madrinha: exibição da marca no Portal Vanguarda.",
    iss: Number(Deno.env.get("NFSE_ISS_COTA") ?? 5),
  },
  curso: {
    codigo: "08.02.01",
    nome: "Instrução, treinamento, orientação pedagógica e educacional, avaliação de conhecimentos de qualquer natureza",
    descricao: "Curso ou mentoria do Portal Vanguarda.",
    iss: Number(Deno.env.get("NFSE_ISS_CURSO") ?? 5),
  },
};

function servicoDoPagamento(externalReference?: string | null): Servico {
  const tipo = (externalReference ?? "").split(":")[0].trim().toLowerCase();
  return SERVICOS[tipo] ?? SERVICOS.apoio;
}

function hojeEmPortoAlegre(): string {
  // AAAA-MM-DD no fuso de Brasília
  return new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
}

async function asaas(path: string, body: unknown) {
  const r = await fetch(`${API}${path}`, {
    method: "POST",
    headers: { "Content-Type": "application/json", "access_token": API_KEY, "User-Agent": "portal-vanguarda" },
    body: JSON.stringify(body),
  });
  const json = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(`Asaas ${r.status}: ${JSON.stringify(json?.errors ?? json)}`);
  return json;
}

// deno-lint-ignore no-explicit-any
async function aoConfirmarPagamento(p: any) {
  const s = servicoDoPagamento(p.externalReference);
  const valor = Number(p.value);

  // Uma nota por pagamento. Reserva a linha antes de chamar o Asaas, para dois avisos
  // simultâneos não gerarem duas notas. Uma tentativa que falhou ao agendar pode ser refeita.
  const { data: existente } = await db.from("notas_fiscais").select("status").eq("pagamento_id", p.id).maybeSingle();
  if (existente) {
    if (existente.status !== "ERRO_AO_AGENDAR") return;
    const { data: retomada } = await db.from("notas_fiscais")
      .update({ status: "AGENDANDO", erro: null, atualizado_em: new Date().toISOString() })
      .eq("pagamento_id", p.id).eq("status", "ERRO_AO_AGENDAR").select("pagamento_id");
    if (!retomada?.length) return; // outra execução já retomou
  } else {
    const { error: reserva } = await db.from("notas_fiscais").insert({
      pagamento_id: p.id, cliente_id: p.customer, servico: s.codigo, valor,
    });
    if (reserva) return; // outra execução já reservou
  }

  try {
    const nota = await asaas("/invoices", {
      payment: p.id,
      serviceDescription: s.descricao,
      observations: "Documento emitido por ME/EPP optante pelo Simples Nacional.",
      externalReference: p.id,
      value: valor,
      deductions: 0,
      effectiveDate: hojeEmPortoAlegre(),
      municipalServiceCode: s.codigo,
      municipalServiceName: s.nome,
      updatePayment: false,
      taxes: { retainIss: false, iss: s.iss, cofins: 0, csll: 0, inss: 0, ir: 0, pis: 0 },
    });
    await db.from("notas_fiscais").update({
      nota_id: nota.id, status: nota.status ?? "SCHEDULED", atualizado_em: new Date().toISOString(),
    }).eq("pagamento_id", p.id);
  } catch (e) {
    await db.from("notas_fiscais").update({
      status: "ERRO_AO_AGENDAR", erro: String(e), atualizado_em: new Date().toISOString(),
    }).eq("pagamento_id", p.id);
    throw e;
  }
}

// deno-lint-ignore no-explicit-any
async function aoAtualizarNota(evento: string, n: any) {
  const linha = {
    nota_id: n.id,
    status: n.status ?? evento.replace("INVOICE_", ""),
    numero: n.number ?? null,
    codigo_verificacao: n.validationCode ?? null,
    pdf_url: n.pdfUrl ?? null,
    xml_url: n.xmlUrl ?? null,
    erro: evento === "INVOICE_ERROR" ? (n.statusDescription ?? "erro sem descrição") : null,
    atualizado_em: new Date().toISOString(),
  };
  if (n.payment) {
    await db.from("notas_fiscais").upsert({
      pagamento_id: n.payment, cliente_id: n.customer, servico: n.municipalServiceCode ?? "",
      valor: Number(n.value ?? 0), ...linha,
    }, { onConflict: "pagamento_id" });
  } else {
    await db.from("notas_fiscais").update(linha).eq("nota_id", n.id);
  }
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return new Response("método não permitido", { status: 405 });
  if (!WEBHOOK_TOKEN || req.headers.get("asaas-access-token") !== WEBHOOK_TOKEN) {
    return new Response("token inválido", { status: 401 });
  }

  const corpo = await req.json().catch(() => null);
  if (!corpo?.event) return new Response("corpo inválido", { status: 400 });

  // O Asaas reenvia eventos; o id do evento garante que cada um é tratado uma vez.
  if (corpo.id) {
    const { error } = await db.from("asaas_eventos").insert({ id: corpo.id, evento: corpo.event });
    if (error) return new Response("já processado", { status: 200 });
  }

  try {
    if ((corpo.event === "PAYMENT_CONFIRMED" || corpo.event === "PAYMENT_RECEIVED") && corpo.payment) {
      await aoConfirmarPagamento(corpo.payment);
    } else if (corpo.event.startsWith("INVOICE_") && corpo.invoice) {
      await aoAtualizarNota(corpo.event, corpo.invoice);
    }
    return new Response("ok", { status: 200 });
  } catch (e) {
    console.error(corpo.event, e);
    // Libera o evento para o Asaas tentar de novo.
    if (corpo.id) await db.from("asaas_eventos").delete().eq("id", corpo.id);
    return new Response("erro ao processar", { status: 500 });
  }
});
