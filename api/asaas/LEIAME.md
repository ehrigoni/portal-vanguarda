# Cobrança do apoio pelo Asaas

O formulário **Apoiar** chama `POST /api/asaas/cobranca` (função da Vercel em `cobranca.js`). A função recalcula o valor (apadrinhados × meses × R$ 1,00), cria ou atualiza o cliente no Asaas pelo CPF/CNPJ, cria uma cobrança única com PIX, boleto ou cartão à escolha do apoiador e devolve o link da fatura, que o site abre.

Sem a chave configurada, o botão Apoiar continua registrando interesse pelo WhatsApp.

## Onde colocar a chave

Nunca no código, no chat ou no `index.html`. Só na Vercel:

1. Vercel > projeto do portal > **Settings > Environment Variables**.
2. Adicione `ASAAS_API_KEY` com a chave do Asaas (marque como *Sensitive*).
3. Adicione `ASAAS_API_URL` (a mesma variável do webhook de notas fiscais):
   - `https://api-sandbox.asaas.com/v3`: chave do sandbox, nenhuma cobrança real. O botão mostra "(teste)".
   - `https://api.asaas.com/v3`: chave da conta real. Cobra de verdade.

   Sem `ASAAS_API_URL`, a função olha `ASAAS_AMBIENTE` (`producao` cobra de verdade; vazio usa o sandbox).
4. Clique em **Redeploy** no último deploy para valer.

A chave do Asaas fica em **Integrações > Chaves de API** no painel (sandbox: sandbox.asaas.com; produção: www.asaas.com). A chave do sandbox não funciona em produção e vice-versa.

Opcionais: `ASAAS_VALOR_MINIMO` (padrão 5, o mínimo que o Asaas aceita por cobrança) e `ASAAS_VENCIMENTO_DIAS` (padrão 3).

## Testar no sandbox

1. Configure a chave do sandbox como acima e faça o redeploy.
2. No site, Apoiar > preencha > **Apoiar (teste)**.
3. Na fatura do sandbox, pague com o PIX de teste ou com o cartão de teste do Asaas.
4. A cobrança aparece em **Cobranças** no painel do sandbox, com a referência `apoio:<apadrinhados>x<meses>m`.

## Notas fiscais (NFS-e)

Quando o pagamento é confirmado, o Asaas chama `POST /api/asaas/webhook` (`webhook.js`, também na Vercel). A função agenda a NFS-e daquele pagamento no próprio Asaas, que transmite ao Sistema Nacional da NFS-e, obrigatório em Porto Alegre. Não há envio separado à prefeitura. Uma nota por pagamento: antes de agendar, a função confere no Asaas se o pagamento já tem nota.

```
Apoiador paga a fatura
  → Asaas: PAYMENT_CONFIRMED / PAYMENT_RECEIVED → /api/asaas/webhook
  → POST /v3/invoices (nota ligada ao pagamento)
  → Asaas envia ao Sistema Nacional NFS-e → nota autorizada → PDF por e-mail ao apoiador
```

### 1. Configurar a parte fiscal no Asaas (uma vez, no painel)

Em **Notas Fiscais > Configurações** (ou pela API `POST /v3/fiscalInfo`):

| Campo | Valor |
| --- | --- |
| Município | Porto Alegre/RS (padrão nacional) |
| Optante pelo Simples Nacional | Sim |
| Regime de apuração do Simples | o do contador (normalmente "apuração pelo Simples Nacional") |
| Inscrição municipal | a da empresa em Porto Alegre |
| CNAE | 6319-4/00 |
| Autenticação | certificado e-CNPJ A1 (.pfx) e senha |
| Série do RPS | entre 00001 e 49999 quando a autenticação é por certificado |
| Próximo número de RPS | 1, se nunca emitiu pelo padrão nacional |
| Local da prestação | cidade da minha conta (Porto Alegre) |

Antes, chame `GET /v3/fiscalInfo/municipalOptions` (ou veja no painel) para conferir quais campos o Asaas pede para Porto Alegre.

**Não** crie configuração de nota por assinatura (`/subscriptions/{id}/invoiceSettings`) nem ative a emissão automática do painel: o webhook já emite uma nota por pagamento, e as duas juntas gerariam nota em dobro.

Em **Notas Fiscais > Configurações**, deixe ligado o envio da nota por e-mail ao cliente.

### 2. Criar o webhook no Asaas

Em **Integrações > Webhooks**, crie um webhook com:

- URL: `https://<endereço do site>/api/asaas/webhook`
- Token de autenticação: o mesmo valor de `ASAAS_WEBHOOK_TOKEN` na Vercel
- Eventos: `PAYMENT_CONFIRMED`, `PAYMENT_RECEIVED`, `PAYMENT_REFUNDED`, `PAYMENT_CHARGEBACK_REQUESTED`, `PAYMENT_DELETED` e todos os `INVOICE_*`

Os eventos de pagamento também alimentam o painel do apoiador: cada apoio confirmado vai para a tabela `apoios` do Supabase, e estornos marcam o apoio como estornado. Para isso, a Vercel precisa de `SUPABASE_SERVICE_ROLE_KEY` (chave service_role do Supabase, em Project Settings > API Keys). Sem ela, a nota sai normalmente e o registro é pulado.
- Fila de sincronização: ativada

Faça isso no sandbox e, depois, de novo na conta de produção: cada ambiente tem os seus webhooks.

### 3. Serviço de cada cobrança

O serviço da nota sai do `externalReference` da cobrança. A cobrança do Apoiar já sai como `apoio:<n>x<meses>m`.


Ao criar a cobrança ou assinatura no Asaas, preencha `externalReference` com o tipo na frente:

| externalReference | Serviço na nota | Código nacional | ISS POA |
| --- | --- | --- | --- |
| `apoio:...` (ou vazio) | Plano de apoio | 01.09.02 | 2% |
| `cota:...` | Cota de empresa madrinha | 17.25.01 | 5% |
| `curso:...` | Curso ou mentoria | 08.02.01 | 5% |

As alíquotas podem ser trocadas pelas variáveis da Vercel `NFSE_ISS_APOIO`, `NFSE_ISS_COTA` e `NFSE_ISS_CURSO`. No Simples Nacional o ISS sai no DAS; a alíquota informada na nota é a da faixa do Simples, então confirme com o contador o valor a usar.

### 4. Testar no sandbox

1. Apoiar no site (modo teste) e pague a fatura com o PIX ou cartão de teste.
2. Em **Notas Fiscais** no painel do sandbox, a nota aparece agendada e depois autorizada.
3. Se não aparecer, veja os logs da Vercel (projeto > **Logs**, filtre por `nfse`). A mensagem do Asaas mostra o que falta; o código de serviço (com ou sem pontos) e a configuração fiscal são os pontos mais prováveis.
