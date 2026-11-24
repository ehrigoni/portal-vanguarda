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
// primeiro agenda. Assinaturas: cada cobrança mensal passa por aqui como um pagamento comum
// (apoio de 1 mês e uma nota por mês).
//
// Variáveis de ambiente na Vercel (as mesmas da cobrança):
//   ASAAS_API_KEY        chave de API
//   ASAAS_API_URL        https://api-sandbox.asaas.com/v3 ou https://api.asaas.com/v3
//   ASAAS_WEBHOOK_TOKEN  o mesmo token informado ao criar o webhook no painel do Asaas
//   NFSE_ISS_APOIO / NFSE_ISS_COTA / NFSE_ISS_CURSO  opcionais; alíquota de ISS (padrão 2 / 5 / 5)
//   SUPABASE_SERVICE_ROLE_KEY  chave de serviço do Supabase, para gravar o apoio na tabela apoios
//                        (painel do apoiador). Sem ela, a nota sai normalmente e o registro é pulado.

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
    // só os erros de validação do Asaas, nunca o corpo inteiro (pode ter dados do cliente)
    const e = new Error("Asaas " + r.status + ": " + JSON.stringify(((json && json.errors) || []).map((x) => x && (x.code || x.description))));
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

// Registro do apoio no Supabase (tabela apoios), base dos números do painel do apoiador.
// Usa a chave de serviço do Supabase, que fica só aqui no servidor. Sem ela, o registro é pulado.
const SUPABASE_URL = (process.env.SUPABASE_URL || "https://ycqhjtlcczcypzdfeznf.supabase.co").trim().replace(/\/+$/, "");
function chaveServico() {
  return String(process.env.SUPABASE_SERVICE_ROLE_KEY || "").trim().replace(/^["'\[]+|["'\]]+$/g, "");
}

async function supabase(method, path, body, prefer) {
  const k = chaveServico();
  // Chave legada (JWT "eyJ...") vai em apikey e Authorization. A chave nova (sb_secret_...) não é JWT:
  // vai só em apikey, porque o Supabase recusa (401) um Authorization: Bearer que não seja JWT.
  const headers = { apikey: k, "Content-Type": "application/json", Prefer: prefer || "return=minimal" };
  if (/^eyJ/.test(k)) headers.Authorization = "Bearer " + k;
  const r = await fetch(SUPABASE_URL + path, {
    method,
    headers,
    body: body ? JSON.stringify(body) : undefined,
  });
  if (!r.ok) {
    // LGPD: o corpo de erro do banco pode repetir a linha enviada (CPF/CNPJ, celular, e-mail); não vai para o log.
    const t = await r.text().catch(() => "");
    let codigo = "";
    try { codigo = String(JSON.parse(t).code || ""); } catch (_) {}
    const e = new Error("Supabase " + r.status + (codigo ? " " + codigo : ""));
    e.supabase = true;
    e.status = r.status; // 4xx (chave errada, tabela ausente) não melhora com reenvio: o handler responde 200
    throw e;
  }
}

// "apoio:3x12m" -> { n: 3, meses: 12 }
function apoioDaReferencia(ref) {
  const m = /^apoio:(\d+)x(\d+)m$/i.exec(String(ref || "").trim());
  return m ? { n: Number(m[1]), meses: Number(m[2]) } : null;
}

async function registrarApoio(p) {
  const a = apoioDaReferencia(p.externalReference);
  if (!a) return { pulado: "não é apoio" };
  if (!chaveServico()) return { pulado: "sem SUPABASE_SERVICE_ROLE_KEY" };
  const cliente = await asaas("GET", "/customers/" + encodeURIComponent(p.customer));
  const doc = String((cliente && cliente.cpfCnpj) || "").replace(/\D/g, "");
  if (doc.length !== 11 && doc.length !== 14) return { pulado: "cliente sem CPF/CNPJ" };
  // celular e e-mail do cliente: o painel só conta o apoio para a conta com o mesmo CPF/CNPJ e o mesmo contato
  let fone = String(cliente.mobilePhone || cliente.phone || "").replace(/\D/g, "");
  if ((fone.length === 12 || fone.length === 13) && fone.startsWith("55")) fone = fone.slice(2);
  const email = String(cliente.email || "").trim().toLowerCase();
  const pagoEm = String(p.clientPaymentDate || p.paymentDate || p.confirmedDate || hojeEmPortoAlegre()).slice(0, 10);
  await supabase("POST", "/rest/v1/apoios", {
    pagamento_id: p.id,
    ambiente: /sandbox/i.test(apiUrl()) ? "sandbox" : "producao",
    doc,
    fone: fone.length === 10 || fone.length === 11 ? fone : null,
    email: email || null,
    vanguardistas: a.n,
    meses: a.meses,
    valor: Number(p.value) || 0,
    pago_em: pagoEm,
  }, "resolution=ignore-duplicates,return=minimal");
  await supabase("POST", "/rest/v1/rpc/alocar_apoios", {});
  return { registrado: true };
}

async function estornarApoio(p) {
  if (!apoioDaReferencia(p.externalReference) || !chaveServico()) return;
  await supabase("PATCH", "/rest/v1/apoios?pagamento_id=eq." + encodeURIComponent(p.id) + "&estornado_em=is.null",
    { estornado_em: new Date().toISOString() });
}

const ESTORNOS = ["PAYMENT_REFUNDED", "PAYMENT_CHARGEBACK_REQUESTED", "PAYMENT_DELETED"];

// Cobrança gerada por assinatura: se vier sem externalReference, usa o da assinatura
// ("apoio:<n>x1m"), para registrar o apoio e escolher o serviço da nota como numa cobrança avulsa.
async function completarReferencia(p) {
  if (p.externalReference || !p.subscription) return;
  try {
    const a = await asaas("GET", "/subscriptions/" + encodeURIComponent(p.subscription));
    if (a && a.externalReference) p.externalReference = a.externalReference;
  } catch (e) {
    console.error("assinatura", p.subscription, String(e));
  }
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
    if (corpo.payment && corpo.event.startsWith("PAYMENT_")) await completarReferencia(corpo.payment);
    if ((corpo.event === "PAYMENT_CONFIRMED" || corpo.event === "PAYMENT_RECEIVED") && corpo.payment) {
      // Registro do apoio e nota são independentes: um erro num não impede o outro. Falha temporária
      // do banco (rede ou 5xx) responde 500 no fim para o Asaas reenviar; os dois passos não duplicam.
      let reenviar = false;
      try {
        const ap = await registrarApoio(corpo.payment);
        console.log("apoio", corpo.event, corpo.payment.id, JSON.stringify(ap));
      } catch (e) {
        console.error("apoio", corpo.event, corpo.payment.id, String(e));
        if (!(e.status >= 400 && e.status < 500)) reenviar = true; // só rede ou 5xx pede reenvio
      }
      const r = await emitirNota(corpo.payment);
      console.log("nfse", corpo.event, corpo.payment.id, JSON.stringify(r));
      if (reenviar) return res.status(500).send("apoio não registrado; tente de novo");
    } else if (ESTORNOS.includes(corpo.event) && corpo.payment) {
      try {
        await estornarApoio(corpo.payment);
        console.log("apoio estornado", corpo.event, corpo.payment.id);
      } catch (e) {
        console.error("apoio", corpo.event, corpo.payment.id, String(e));
        // só falha temporária do banco (rede ou 5xx) pede reenvio; o resto fica no log
        if (!(e.status >= 400 && e.status < 500)) return res.status(500).send("estorno não registrado; tente de novo");
      }
    } else if (String(corpo.event).startsWith("INVOICE_") && corpo.invoice) {
      const n = corpo.invoice;
      const log = corpo.event === "INVOICE_ERROR" ? console.error : console.log;
      // sem o link do PDF: a nota tem nome e CPF/CNPJ do cliente (LGPD)
      log("nfse", corpo.event, n.id, n.payment || "", n.status || "", n.statusDescription || "");
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
