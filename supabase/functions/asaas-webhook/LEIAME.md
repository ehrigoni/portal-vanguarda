# Notas fiscais automáticas pelo Asaas (Porto Alegre)

Quando um pagamento é confirmado no Asaas, o webhook `asaas-webhook` agenda a NFS-e daquele pagamento no próprio Asaas. O Asaas transmite a nota ao Sistema Nacional da NFS-e, que é o sistema obrigatório em Porto Alegre desde 1º de novembro de 2025. Nota autorizada já está registrada na prefeitura: não há um segundo envio a fazer.

```
Pagamento confirmado no Asaas
  → webhook PAYMENT_CONFIRMED / PAYMENT_RECEIVED
  → função agenda a nota (POST /v3/invoices)
  → Asaas envia ao Sistema Nacional NFS-e (INVOICE_SYNCHRONIZED)
  → nota autorizada (INVOICE_AUTHORIZED): número, PDF e XML gravados em notas_fiscais
```

## 1. Configurar a parte fiscal no Asaas (uma vez, no painel)

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

**Não** crie configuração de nota por assinatura (`/subscriptions/{id}/invoiceSettings`) nem ative a emissão automática do painel: esta função já emite uma nota por pagamento, e as duas juntas gerariam nota em dobro.

## 2. Banco de dados

No Supabase, rode `supabase/nfse.sql` no SQL Editor.

## 3. Publicar a função

```bash
supabase secrets set ASAAS_API_KEY='$aact_...' ASAAS_WEBHOOK_TOKEN='um-token-longo-e-aleatorio'
# para testar no sandbox antes:
# supabase secrets set ASAAS_API_URL='https://api-sandbox.asaas.com/v3'
supabase functions deploy asaas-webhook --no-verify-jwt
```

`--no-verify-jwt` é necessário porque quem chama é o Asaas; a função confere o token do webhook.

## 4. Criar o webhook no Asaas

Em **Integrações > Webhooks**, crie um webhook com:

- URL: `https://<projeto>.supabase.co/functions/v1/asaas-webhook`
- Token de autenticação: o mesmo `ASAAS_WEBHOOK_TOKEN`
- Eventos: `PAYMENT_CONFIRMED`, `PAYMENT_RECEIVED` e todos os `INVOICE_*`

## 5. Dizer à função que serviço é cada cobrança

Ao criar a cobrança ou assinatura no Asaas, preencha `externalReference` com o tipo na frente:

| externalReference | Serviço na nota | Código nacional | ISS POA |
| --- | --- | --- | --- |
| `apoio:...` (ou vazio) | Plano de apoio | 01.09.02 | 2% |
| `cota:...` | Cota de empresa madrinha | 17.25.01 | 5% |
| `curso:...` | Curso ou mentoria | 08.02.01 | 5% |

As alíquotas podem ser trocadas pelos segredos `NFSE_ISS_APOIO`, `NFSE_ISS_COTA` e `NFSE_ISS_CURSO`. No Simples Nacional o ISS sai no DAS; a alíquota informada na nota é a da faixa do Simples, então confirme com o contador o valor a usar.

## 6. Testar

1. No sandbox do Asaas, crie uma cobrança de R$ 1,00 com `externalReference` = `apoio:teste` e marque como recebida.
2. Em **Table Editor > notas_fiscais**, a linha deve passar de `AGENDANDO` para `SCHEDULED`, depois `SYNCHRONIZED` e `AUTHORIZED`, com `pdf_url` preenchido.
3. Se ficar em `ERRO_AO_AGENDAR` ou `ERROR`, a coluna `erro` traz a mensagem do Asaas ou da prefeitura. O código de serviço é o ponto mais provável de ajuste: confira no painel do Asaas o formato que ele aceita (com ou sem pontos).
