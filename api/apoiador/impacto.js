// Portal Vanguarda: impacto financeiro do apoiador logado (função da Vercel).
//
// O painel do apoiador chama GET /api/apoiador/impacto com o token da sessão do Supabase
// (Authorization: Bearer <access_token>). Esta função:
//   1. confere o token no Supabase e lê o CPF/CNPJ do próprio perfil (a RLS só deixa ler o próprio);
//   2. busca no Asaas o cliente com esse CPF/CNPJ e os pagamentos já recebidos;
//   3. soma os apadrinhamentos a partir do externalReference "apoio:<n>x<meses>m" (ver api/asaas/cobranca.js).
// Devolve só números do próprio apoiador; a chave do Asaas nunca sai do servidor.
//
// Variáveis de ambiente: as mesmas da cobrança (ASAAS_API_KEY, ASAAS_API_URL).
// SUPABASE_URL e SUPABASE_ANON_KEY são opcionais; sem elas valem as chaves públicas do index.html.

const SUPABASE_URL = (process.env.SUPABASE_URL || "https://ycqhjtlcczcypzdfeznf.supabase.co").trim().replace(/\/+$/, "");
const SUPABASE_ANON_KEY = (process.env.SUPABASE_ANON_KEY || "sb_publishable_HTyKQ4PwyVEkjpARrwBriA_qeVpZyC5").trim();
const CUSTO_MEDIO = 1; // R$ por vanguardista por mês; igual a CUSTO_MEDIO no index.html
const PAGOS = ["RECEIVED", "CONFIRMED", "RECEIVED_IN_CASH"];

function apiUrl() {
  const url = (process.env.ASAAS_API_URL || "").trim().replace(/^[\[\s"'<]+|[\]\s"'>]+$/g, "").replace(/\/+$/, "");
  if (url) return url;
  return (process.env.ASAAS_AMBIENTE || "").trim().toLowerCase() === "producao"
    ? "https://api.asaas.com/v3" : "https://api-sandbox.asaas.com/v3";
}

async function asaas(path) {
  const r = await fetch(apiUrl() + path, {
    headers: {
      access_token: String(process.env.ASAAS_API_KEY || "").trim().replace(/^["']|["']$/g, ""),
      "User-Agent": "portal-vanguarda",
    },
  });
  const json = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error("Asaas " + r.status);
  return json;
}

async function supabase(path, token) {
  const r = await fetch(SUPABASE_URL + path, { headers: { apikey: SUPABASE_ANON_KEY, Authorization: "Bearer " + token } });
  if (!r.ok) return null;
  return r.json().catch(() => null);
}

// "apoio:3x12m" -> { n: 3, meses: 12 }
function apoio(ref) {
  const m = /^apoio:(\d+)x(\d+)m$/i.exec(String(ref || "").trim());
  return m ? { n: Number(m[1]), meses: Number(m[2]) } : null;
}

function somaMeses(dataIso, meses) {
  const d = new Date(dataIso + "T12:00:00Z");
  d.setUTCMonth(d.getUTCMonth() + meses);
  return d.toISOString().slice(0, 10);
}

function resumir(pagamentos, hoje) {
  const r = { apoios: 0, valor_total: 0, vanguardistas_ativos: 0, vanguardistas_total: 0, meses_vanguardista: 0, desde: null, ate: null };
  for (const p of pagamentos) {
    if (!PAGOS.includes(p.status)) continue;
    const a = apoio(p.externalReference);
    if (!a) continue;
    const data = String(p.clientPaymentDate || p.paymentDate || p.confirmedDate || p.dateCreated || hoje).slice(0, 10);
    const fim = somaMeses(data, a.meses);
    r.apoios += 1;
    r.valor_total += Number(p.value) || a.n * a.meses * CUSTO_MEDIO;
    r.vanguardistas_total += a.n;
    r.meses_vanguardista += a.n * a.meses;
    if (fim >= hoje) {
      r.vanguardistas_ativos += a.n;
      if (!r.ate || fim > r.ate) r.ate = fim;
    }
    if (!r.desde || data < r.desde) r.desde = data;
  }
  r.valor_total = Math.round(r.valor_total * 100) / 100;
  return r;
}

module.exports = async function handler(req, res) {
  res.setHeader("Cache-Control", "no-store");
  if (req.method !== "GET") {
    res.setHeader("Allow", "GET");
    return res.status(405).json({ erro: "Método não permitido." });
  }
  const token = String(req.headers.authorization || "").replace(/^Bearer\s+/i, "").trim();
  if (!token) return res.status(401).json({ erro: "Entre na sua conta." });

  const user = await supabase("/auth/v1/user", token);
  if (!user || !user.id) return res.status(401).json({ erro: "Sessão expirada. Entre de novo." });
  const perfis = await supabase("/rest/v1/perfis?select=tipo,doc&id=eq." + encodeURIComponent(user.id), token);
  const perfil = Array.isArray(perfis) && perfis[0];
  if (!perfil || perfil.tipo !== "apoiador") return res.status(403).json({ erro: "Disponível só para apoiadores." });

  const hoje = new Date().toLocaleDateString("sv-SE", { timeZone: "America/Sao_Paulo" });
  const vazio = { ok: true, ...resumir([], hoje) };
  if (!process.env.ASAAS_API_KEY) return res.status(200).json({ ...vazio, cobranca: false });

  try {
    const doc = String(perfil.doc || "").replace(/\D/g, "");
    const clientes = await asaas("/customers?cpfCnpj=" + doc + "&limit=10");
    const ids = ((clientes && clientes.data) || []).filter((c) => !c.deleted).map((c) => c.id);
    const pagamentos = [];
    for (const id of ids) {
      for (let offset = 0; offset < 1000; offset += 100) {
        const pg = await asaas("/payments?customer=" + id + "&limit=100&offset=" + offset);
        pagamentos.push(...((pg && pg.data) || []));
        if (!pg || !pg.hasMore) break;
      }
    }
    return res.status(200).json({ ok: true, ambiente: /sandbox/i.test(apiUrl()) ? "sandbox" : "producao", ...resumir(pagamentos, hoje) });
  } catch (e) {
    return res.status(502).json({ erro: "Não foi possível consultar os apoios agora." });
  }
};

module.exports.resumir = resumir;
