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

## Notas fiscais

O webhook em `supabase/functions/asaas-webhook` reconhece o prefixo `apoio:` e emite a NFS-e de cada pagamento confirmado. Ele usa a mesma chave, cadastrada também nos segredos do Supabase (veja o LEIAME de lá).

`ASAAS_WEBHOOK_TOKEN` é só do webhook (confere que o aviso veio do Asaas); a criação da cobrança não usa.
