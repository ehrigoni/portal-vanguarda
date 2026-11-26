// Portal Vanguarda: cria a cobrança do apoio no Asaas (função da Vercel).
//
// O site manda quantos vanguardistas e por quantos meses, mais os dados do apoiador.
// Esta função:
//   1. recalcula o valor aqui no servidor (nunca confia no total que veio do navegador);
//   2. procura o cliente no Asaas pelo CPF/CNPJ e cria se não existir;
//   3. cria a cobrança com billingType UNDEFINED (o apoiador escolhe PIX, boleto ou cartão);
//   4. devolve o link da fatura (invoiceUrl) para o site abrir.
//   Com assinatura: true, cria uma assinatura mensal (POST /subscriptions) em vez de uma cobrança
//   avulsa e devolve o link da primeira fatura.
//
// O externalReference sai como "apoio:<n>x<meses>m", o mesmo prefixo que o webhook
// de notas fiscais (supabase/functions/asaas-webhook) usa para escolher o serviço da NFS-e.
//
// Variáveis de ambiente (Vercel > Project > Settings > Environment Variables):
//   ASAAS_API_KEY       chave de API do Asaas. Nunca vai para o código nem para o navegador.
//   ASAAS_API_URL       https://api-sandbox.asaas.com/v3 (teste) ou https://api.asaas.com/v3 (cobra de verdade).
//                       Se não existir, vale ASAAS_AMBIENTE: "producao" cobra de verdade; outro valor ou vazio usa o sandbox.
//   ASAAS_VALOR_MINIMO  opcional; menor cobrança aceita, padrão 5 (mínimo do Asaas por cobrança).
//   ASAAS_VENCIMENTO_DIAS opcional; dias até o vencimento, padrão 3.
//   SUPABASE_URL / SUPABASE_ANON_KEY opcionais; de onde vem o preço (padrão: o mesmo projeto e a chave pública do site).
//
// Preço e períodos: vêm de config_site.apoio no Supabase, editados na aba Administrador > Preço e períodos
// (valor unitário por vanguardista a cada mês, períodos oferecidos, "Outro" e assinatura ligados ou não).
// Total = valor unitário x apadrinhados x meses, sempre calculado aqui. Sem a linha no banco, vale APOIO_PADRAO.

const APOIO_PADRAO = { valor_unitario: 156, periodos: [1, 6, 12], outro: true, assinatura: true }; // igual ao index.html
const SUPABASE_URL = (process.env.SUPABASE_URL || "https://ycqhjtlcczcypzdfeznf.supabase.co").trim().replace(/\/+$/, "");
const SUPABASE_PUBLICA = (process.env.SUPABASE_ANON_KEY || "sb_publishable_HTyKQ4PwyVEkjpARrwBriA_qeVpZyC5").trim();
const MAX_VANGUARDISTAS = 1000;
const MAX_MESES = 120;

const URL_PRODUCAO = "https://api.asaas.com/v3";
const URL_SANDBOX = "https://api-sandbox.asaas.com/v3";

function apiUrl() {
  // ASAAS_API_URL, quando existe, manda (é a mesma variável do webhook de notas fiscais)
  // tolera o valor colado com colchetes, aspas ou espaços: [https://...], "https://..."
  const url = (process.env.ASAAS_API_URL || "").trim().replace(/^[\[\s"'<]+|[\]\s"'>]+$/g, "").replace(/\/+$/, "");
  if (url) return url;
  return (process.env.ASAAS_AMBIENTE || "").trim().toLowerCase() === "producao" ? URL_PRODUCAO : URL_SANDBOX;
}

function ambiente() {
  return /sandbox/i.test(apiUrl()) ? "sandbox" : "producao";
}

const dig = (v) => String(v ?? "").replace(/\D/g, "");
const txt = (v, max) => String(v ?? "").trim().slice(0, max);

function cpfOk(d) {
  if (d.length !== 11 || /^(\d)\1+$/.test(d)) return false;
  for (let t = 9; t < 11; t++) {
    let s = 0;
    for (let k = 0; k < t; k++) s += Number(d[k]) * (t + 1 - k);
    if (((s * 10) % 11) % 10 !== Number(d[t])) return false;
  }
  return true;
}

function cnpjOk(d) {
  if (d.length !== 14 || /^(\d)\1+$/.test(d)) return false;
  const dv = (n) => {
    const w = n === 12 ? [5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2] : [6, 5, 4, 3, 2, 9, 8, 7, 6, 5, 4, 3, 2];
    let s = 0;
    for (let k = 0; k < n; k++) s += Number(d[k]) * w[k];
    const r = s % 11;
    return r < 2 ? 0 : 11 - r;
  };
  return dv(12) === Number(d[12]) && dv(13) === Number(d[13]);
}

function inteiro(v, max) {
  const n = Number(v);
  return Number.isInteger(n) && n >= 1 && n <= max ? n : null;
}

// Lê config_site.apoio (leitura pública). Guarda por 60 s. Se o banco não responder, a cobrança para
// (melhor não cobrar do que cobrar um valor diferente do que o site mostrou).
let cacheApoio = { t: 0, v: null };
function normalizarApoio(v) {
  const o = v && typeof v === "object" ? v : {};
  const un = Number(o.valor_unitario);
  const per = Array.isArray(o.periodos) ? o.periodos.map(Number).filter((n) => Number.isInteger(n) && n >= 1 && n <= MAX_MESES) : [];
  return {
    valor_unitario: un > 0 ? un : APOIO_PADRAO.valor_unitario,
    periodos: per.length ? per : APOIO_PADRAO.periodos,
    outro: o.outro !== false,
    assinatura: o.assinatura !== false,
  };
}
async function configApoio() {
  if (cacheApoio.v && Date.now() - cacheApoio.t < 60000) return cacheApoio.v;
  const headers = { apikey: SUPABASE_PUBLICA };
  if (/^eyJ/.test(SUPABASE_PUBLICA)) headers.Authorization = "Bearer " + SUPABASE_PUBLICA;
  const r = await fetch(SUPABASE_URL + "/rest/v1/config_site?chave=eq.apoio&select=valor", { headers });
  if (!r.ok) throw new Error("config " + r.status);
  const linhas = await r.json();
  const v = normalizarApoio(Array.isArray(linhas) && linhas[0] ? linhas[0].valor : null);
  cacheApoio = { t: Date.now(), v };
  return v;
}

function vencimento() {
  const dias = Number(process.env.ASAAS_VENCIMENTO_DIAS) > 0 ? Number(process.env.ASAAS_VENCIMENTO_DIAS) : 3;
  const d = new Date(Date.now() + dias * 86400000);
  return d.toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" }); // AAAA-MM-DD
}

async function asaas(method, path, body) {
  const r = await fetch(apiUrl() + path, {
    method,
    headers: {
      "Content-Type": "application/json",
      access_token: String(process.env.ASAAS_API_KEY || "").trim().replace(/^["']|["']$/g, ""),
      "User-Agent": "portal-vanguarda",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error("Asaas " + r.status);
    e.status = r.status;
    e.detalhes = (json && json.errors) || []; // só os erros de validação, nunca o corpo inteiro (LGPD)
    throw e;
  }
  return json;
}

// Importa o apoiador no Asaas a cada apoio: procura pelo CPF/CNPJ e cria ou atualiza o cadastro com
// nome, e-mail, celular e endereço do formulário. A NFS-e e o envio da nota por e-mail usam esses dados,
// então uma falha aqui interrompe a cobrança (o apoiador tenta de novo) em vez de seguir com dados velhos.
async function clienteAsaas(d) {
  const achou = await asaas("GET", "/customers?cpfCnpj=" + d.doc + "&limit=10");
  const dados = {
    name: d.nome,
    cpfCnpj: d.doc,
    email: d.email,
    mobilePhone: d.fone,
    postalCode: d.cep,
    address: d.endereco,
    province: d.bairro,
    addressNumber: d.numero,
    complement: d.complemento || "",
    externalReference: "portal-vanguarda",
    notificationDisabled: false, // o Asaas manda fatura e nota por e-mail ao cliente
  };
  const existente = achou && Array.isArray(achou.data) && achou.data.find((c) => !c.deleted);
  if (existente) {
    await asaas("PUT", "/customers/" + existente.id, dados);
    console.log("asaas cliente atualizado", existente.id);
    return existente.id;
  }
  const novo = await asaas("POST", "/customers", dados);
  console.log("asaas cliente criado", novo.id);
  return novo.id;
}

module.exports = async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");

  if (req.method === "GET") {
    // o site pergunta se a cobrança está ligada; não revela nada da chave
    return res.status(200).json({ ativo: !!process.env.ASAAS_API_KEY, ambiente: ambiente() });
  }
  if (req.method !== "POST") {
    res.setHeader("Allow", "GET, POST");
    return res.status(405).json({ erro: "Método não permitido." });
  }
  if (!process.env.ASAAS_API_KEY) {
    return res.status(503).json({ erro: "Cobrança ainda não configurada.", codigo: "sem_chave" });
  }

  let b = req.body;
  if (typeof b === "string") {
    try { b = JSON.parse(b); } catch { b = null; }
  }
  if (!b || typeof b !== "object") return res.status(400).json({ erro: "Dados inválidos." });

  let cfg;
  try {
    cfg = await configApoio();
  } catch (e) {
    console.error("config apoio", String(e && e.message));
    return res.status(503).json({ erro: "Não foi possível consultar o valor do apoio agora. Tente de novo em instantes.", codigo: "sem_config" });
  }
  const n = inteiro(b.vanguardistas, MAX_VANGUARDISTAS);
  const assinatura = b.assinatura === true;
  if (assinatura && !cfg.assinatura) return res.status(400).json({ erro: "A assinatura mensal não está disponível no momento.", codigo: "periodo_indisponivel" });
  let meses = assinatura ? 1 : inteiro(b.meses, MAX_MESES); // assinatura: cada cobrança mensal paga 1 mês
  if (meses && !assinatura && !cfg.outro && cfg.periodos.indexOf(meses) < 0) {
    return res.status(400).json({ erro: "Escolha um dos períodos oferecidos: " + cfg.periodos.join(", ") + " meses.", codigo: "periodo_indisponivel" });
  }
  const CUSTO_MEDIO = cfg.valor_unitario;
  const d = {
    nome: txt(b.nome, 120),
    email: txt(b.email, 120).toLowerCase(),
    fone: dig(b.fone),
    doc: dig(b.doc),
    cep: dig(b.cep),
    endereco: txt(b.endereco, 160),
    bairro: txt(b.bairro, 80),
    numero: txt(b.numero, 10),
    complemento: txt(b.complemento, 60),
  };
  const faltando = [];
  if (!n) faltando.push("número de apadrinhados");
  if (!meses) faltando.push("período");
  if (!d.nome) faltando.push("nome");
  if (d.fone.length !== 10 && d.fone.length !== 11) faltando.push("celular");
  if (!cpfOk(d.doc) && !cnpjOk(d.doc)) faltando.push("CPF ou CNPJ");
  if (d.cep.length !== 8) faltando.push("CEP");
  if (!d.endereco) faltando.push("rua");
  if (!d.bairro) faltando.push("bairro");
  if (!d.numero) faltando.push("número");
  // o Asaas só emite a NFS-e se o cliente tiver e-mail
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(d.email)) faltando.push("e-mail");
  if (faltando.length) return res.status(400).json({ erro: "Confira: " + faltando.join(", ") + "." });

  const valor = Math.round(n * meses * CUSTO_MEDIO * 100) / 100;
  const minimo = Number(process.env.ASAAS_VALOR_MINIMO || 5);
  if (valor < minimo) {
    const fmt = (v) => v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
    return res.status(400).json({
      erro: "O valor mínimo por pagamento é " + fmt(minimo) + (assinatura ? ". Na assinatura, apadrinhe pelo menos " + Math.ceil(minimo / CUSTO_MEDIO) + " vanguardistas." : ". Aumente o número de apadrinhados ou o período."),
      codigo: "abaixo_do_minimo",
    });
  }

  try {
    const customer = await clienteAsaas(d);
    const plural = (q, s, p) => q + " " + (q === 1 ? s : p);
    if (assinatura) {
      // Assinatura mensal: o Asaas gera uma cobrança por mês com o mesmo externalReference, e o
      // webhook trata cada pagamento como um apoio de 1 mês (registro no painel e NFS-e).
      const ass = await asaas("POST", "/subscriptions", {
        customer,
        billingType: "UNDEFINED",
        value: valor,
        nextDueDate: vencimento(),
        cycle: "MONTHLY",
        description: "Apoio mensal ao Portal Vanguarda: " + plural(n, "vanguardista apadrinhado", "vanguardistas apadrinhados") + " por mês.",
        externalReference: "apoio:" + n + "x1m",
      });
      const pags = await asaas("GET", "/subscriptions/" + encodeURIComponent(ass.id) + "/payments?limit=1").catch(() => null);
      const primeira = pags && Array.isArray(pags.data) && pags.data[0];
      return res.status(200).json({
        ok: true,
        ambiente: ambiente(),
        valor,
        assinatura: ass.id,
        link: primeira ? primeira.invoiceUrl : null,
        id: primeira ? primeira.id : null,
      });
    }
    const cobranca = await asaas("POST", "/payments", {
      customer,
      billingType: "UNDEFINED",
      value: valor,
      dueDate: vencimento(),
      description: "Apoio ao Portal Vanguarda: " + plural(n, "vanguardista apadrinhado", "vanguardistas apadrinhados") +
        " por " + plural(meses, "mês", "meses") + ".",
      externalReference: "apoio:" + n + "x" + meses + "m",
    });
    return res.status(200).json({
      ok: true,
      ambiente: ambiente(),
      valor,
      link: cobranca.invoiceUrl,
      id: cobranca.id,
    });
  } catch (e) {
    console.error("asaas", e.status, JSON.stringify(Array.isArray(e.detalhes) ? e.detalhes.map((x) => x && (x.code || x.description)) : e.message));
    if (e.status === 401) {
      return res.status(502).json({ erro: "Cobrança indisponível no momento.", codigo: "chave_recusada" });
    }
    const msg = Array.isArray(e.detalhes) && e.detalhes[0] && e.detalhes[0].description;
    return res.status(502).json({ erro: msg ? "O Asaas recusou: " + msg : "Não foi possível criar a cobrança agora. Tente de novo em instantes." });
  }
};
