// Portal Vanguarda: webhook do Asaas que emite a NFS-e de cada pagamento (função da Vercel).
//
// Fluxo:
//   1. O apoiador paga a fatura criada por api/asaas/cobranca.js.
//   2. O Asaas avisa aqui (PAYMENT_CONFIRMED ou PAYMENT_RECEIVED).
//   3. Esta função agenda a nota no Asaas (POST /invoices) ligada àquele pagamento.
//   4. O Asaas transmite a nota ao Sistema Nacional da NFS-e (o que Porto Alegre usa)
//      e manda o PDF por e-mail ao cliente, se o envio estiver ligado no painel.
//
// Uma nota por pagamento: antes de agendar, a função pergunta ao Asaas se aquele pagamento
// já tem nota (GET /invoices?payment=...). Cartão gera CONFIRMED e depois RECEIVED; só o
// primeiro agenda.
//
// Variáveis de ambiente na Vercel (as mesmas da cobrança):
//   ASAAS_API_KEY        chave de API
//   ASAAS_API_URL        https://api-sandbox.asaas.com/v3 ou https://api.asaas.com/v3
//   ASAAS_WEBHOOK_TOKEN  o mesmo token informado ao criar o webhook no painel do Asaas
//   NFSE_ISS_APOIO / NFSE_ISS_COTA / NFSE_ISS_CURSO  opcionais; alíquota de ISS (padrão 2 / 5 / 5)

const SERVICOS = {
  apoio: {
    codigo: "01.09.02",
    nome: "Disponibilização, sem cessão definitiva, de conteúdos de vídeo, imagem e texto por meio da internet",
    descricao: "Plano de apoio ao Portal Vanguarda: acesso a conteúdos, simuladores e comunidade pela internet.",
    iss: () => Number(process.env.NFSE_ISS_APOIO || 2),
  },
  cota: {
    codigo: "17.25.01",
    nome: "Inserção de textos, desenhos e outros materiais de propaganda e publicidade, em qualquer meio",
    descricao: "Cota de empresa madrinha: exibição da marca no Portal Vanguarda.",
    iss: () => Number(process.env.NFSE_ISS_COTA || 5),
  },
  curso: {
    codigo: "08.02.01",
    nome: "Instrução, treinamento, orientação pedagógica e educacional, avaliação de conhecimentos de qualquer natureza",
    descricao: "Curso ou mentoria do Portal Vanguarda.",
    iss: () => Number(process.env.NFSE_ISS_CURSO || 5),
  },
};

// O tipo vem do externalReference da cobrança ("apoio:3x12m", "cota:...", "curso:...").
function servicoDoPagamento(ref) {
  const tipo = String(ref || "").split(":")[0].trim().toLowerCase();
  return SERVICOS[tipo] || SERVICOS.apoio;
}

function apiUrl() {
  // tolera o valor colado com colchetes, aspas ou espaços: [https://...], "https://..."
  const url = (process.env.ASAAS_API_URL || "").trim().replace(/^[\[\s"'<]+|[\]\s"'>]+$/g, "").replace(/\/+$/, "");
  if (url) return url;
  return (process.env.ASAAS_AMBIENTE || "").trim().toLowerCase() === "producao"
    ? "https://api.asaas.com/v3" : "https://api-sandbox.asaas.com/v3";
}

function hojeEmPortoAlegre() {
  return new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
}

async function asaas(method, path, body) {
  const r = await fetch(apiUrl() + path, {
    method,
    headers: { "Content-Type": "application/json", access_token: String(process.env.ASAAS_API_KEY || "").trim().replace(/^["']|["']$/g, ""), "User-Agent": "portal-vanguarda" },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error("Asaas " + r.status + ": " + JSON.stringify((json && json.errors) || json));
    e.status = r.status;
    throw e;
  }
  return json;
}

async function emitirNota(p) {
  const existentes = await asaas("GET", "/invoices?payment=" + encodeURIComponent(p.id) + "&limit=10");
  const ativa = (existentes.data || []).find((n) => !/CANCEL/i.test(n.status || ""));
  if (ativa) return { ja: true, nota: ativa.id, status: ativa.status };

  const s = servicoDoPagamento(p.externalReference);
  const nota = await asaas("POST", "/invoices", {
    payment: p.id,
    serviceDescription: s.descricao,
    observations: "Documento emitido por ME/EPP optante pelo Simples Nacional.",
    externalReference: p.id,
    value: Number(p.value),
    deductions: 0,
    effectiveDate: hojeEmPortoAlegre(),
    municipalServiceCode: s.codigo,
    municipalServiceName: s.nome,
    updatePayment: false,
    taxes: { retainIss: false, iss: s.iss(), cofins: 0, csll: 0, inss: 0, ir: 0, pis: 0 },
  });
  return { ja: false, nota: nota.id, status: nota.status };
}

module.exports = async function handler(req, res) {
  if (req.method !== "POST") {
    res.setHeader("Allow", "POST");
    return res.status(405).send("método não permitido");
  }
  // tolera colchetes, aspas ou espaços colados nas pontas, dos dois lados
  const limpa = (v) => String(v || "").trim().replace(/^[\[\s"'<]+|[\]\s"'>]+$/g, "");
  const token = limpa(process.env.ASAAS_WEBHOOK_TOKEN);
  const recebido = limpa(req.headers["asaas-access-token"]);
  if (!token || recebido !== token) {
    console.error("nfse token recusado", "recebido:", recebido ? recebido.length + " caracteres" : "nenhum", "esperado:", token.length + " caracteres");
    return res.status(401).send("token inválido");
  }
  if (!process.env.ASAAS_API_KEY) return res.status(503).send("sem chave");

  let corpo = req.body;
  if (typeof corpo === "string") {
    try { corpo = JSON.parse(corpo); } catch { corpo = null; }
  }
  if (!corpo || !corpo.event) return res.status(400).send("corpo inválido");

  try {
    if ((corpo.event === "PAYMENT_CONFIRMED" || corpo.event === "PAYMENT_RECEIVED") && corpo.payment) {
      const r = await emitirNota(corpo.payment);
      console.log("nfse", corpo.event, corpo.payment.id, JSON.stringify(r));
    } else if (String(corpo.event).startsWith("INVOICE_") && corpo.invoice) {
      const n = corpo.invoice;
      const log = corpo.event === "INVOICE_ERROR" ? console.error : console.log;
      log("nfse", corpo.event, n.id, n.payment || "", n.status || "", n.statusDescription || "", n.pdfUrl || "");
    }
    return res.status(200).send("ok");
  } catch (e) {
    console.error("nfse", corpo.event, String(e));
    // Recusa do Asaas (4xx, ex.: configuração fiscal incompleta) não melhora com reenvio, e
    // erros seguidos pausam a fila de webhooks: responde 200 e fica no log da Vercel.
    // Falha de rede ou 5xx: 500 faz o Asaas reenviar depois.
    if (e.status >= 400 && e.status < 500) return res.status(200).send("recusado pelo Asaas");
    return res.status(500).send("erro ao processar");
  }
};
