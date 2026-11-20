// Portal Vanguarda: cria a cobrança do apoio no Asaas (função da Vercel).
//
// O site manda quantos vanguardistas e por quantos meses, mais os dados do apoiador.
// Esta função:
//   1. recalcula o valor aqui no servidor (nunca confia no total que veio do navegador);
//   2. procura o cliente no Asaas pelo CPF/CNPJ e cria se não existir;
//   3. cria a cobrança com billingType UNDEFINED (o apoiador escolhe PIX, boleto ou cartão);
//   4. devolve o link da fatura (invoiceUrl) para o site abrir.
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

const CUSTO_MEDIO = 1; // R$ por vanguardista por mês; igual a CUSTO_MEDIO no index.html
const MAX_VANGUARDISTAS = 1000;
const MAX_MESES = 120;

const URL_PRODUCAO = "https://api.asaas.com/v3";
const URL_SANDBOX = "https://api-sandbox.asaas.com/v3";

function apiUrl() {
  // ASAAS_API_URL, quando existe, manda (é a mesma variável do webhook de notas fiscais)
  const url = (process.env.ASAAS_API_URL || "").trim().replace(/\/+$/, "");
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
      access_token: process.env.ASAAS_API_KEY,
      "User-Agent": "portal-vanguarda",
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const json = await r.json().catch(() => ({}));
  if (!r.ok) {
    const e = new Error("Asaas " + r.status);
    e.status = r.status;
    e.detalhes = (json && json.errors) || json;
    throw e;
  }
  return json;
}

async function clienteAsaas(d) {
  const achou = await asaas("GET", "/customers?cpfCnpj=" + d.doc + "&limit=1");
  const dados = {
    name: d.nome,
    cpfCnpj: d.doc,
    mobilePhone: d.fone,
    postalCode: d.cep,
    address: d.endereco,
    addressNumber: d.numero,
    complement: d.complemento || undefined,
    externalReference: "portal-vanguarda",
  };
  if (d.email) dados.email = d.email;
  const existente = achou && Array.isArray(achou.data) && achou.data.find((c) => !c.deleted);
  if (existente) {
    // atualiza contato e endereço para a fatura e a nota saírem com os dados novos
    await asaas("PUT", "/customers/" + existente.id, dados).catch(() => {});
    return existente.id;
  }
  const novo = await asaas("POST", "/customers", dados);
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

  const n = inteiro(b.vanguardistas, MAX_VANGUARDISTAS);
  const meses = inteiro(b.meses, MAX_MESES);
  const d = {
    nome: txt(b.nome, 120),
    email: txt(b.email, 120).toLowerCase(),
    fone: dig(b.fone),
    doc: dig(b.doc),
    cep: dig(b.cep),
    endereco: txt(b.endereco, 160),
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
  if (!d.endereco) faltando.push("endereço");
  if (!d.numero) faltando.push("número");
  if (d.email && !/^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/.test(d.email)) faltando.push("e-mail");
  if (faltando.length) return res.status(400).json({ erro: "Confira: " + faltando.join(", ") + "." });

  const valor = Math.round(n * meses * CUSTO_MEDIO * 100) / 100;
  const minimo = Number(process.env.ASAAS_VALOR_MINIMO || 5);
  if (valor < minimo) {
    const fmt = (v) => v.toLocaleString("pt-BR", { style: "currency", currency: "BRL" });
    return res.status(400).json({
      erro: "O valor mínimo por pagamento é " + fmt(minimo) + ". Aumente o número de apadrinhados ou o período.",
      codigo: "abaixo_do_minimo",
    });
  }

  try {
    const customer = await clienteAsaas(d);
    const plural = (q, s, p) => q + " " + (q === 1 ? s : p);
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
    console.error("asaas", e.status, JSON.stringify(e.detalhes || e.message));
    if (e.status === 401) {
      return res.status(502).json({ erro: "Cobrança indisponível no momento.", codigo: "chave_recusada" });
    }
    const msg = Array.isArray(e.detalhes) && e.detalhes[0] && e.detalhes[0].description;
    return res.status(502).json({ erro: msg ? "O Asaas recusou: " + msg : "Não foi possível criar a cobrança agora. Tente de novo em instantes." });
  }
};
