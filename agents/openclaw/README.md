# OpenClaw — Gambiarra Sentinel

Perfil de agente **read-only** para monitorar a Gambiarra Finance. O OpenClaw lê
`SOUL.md` como instrução central do workspace.

## Setup

1. Crie um workspace dedicado (não use o repo com permissão de escrita):

   ```bash
   mkdir -p ~/gambiarra-sentinel
   cp agents/openclaw/SOUL.md ~/gambiarra-sentinel/SOUL.md
   ```

2. Registre o agente (ajuste modelo/canal conforme seu setup):

   ```bash
   openclaw agents add gambiarra-sentinel \
     --workspace ~/gambiarra-sentinel \
     --description "Analista read-only da Gambiarra Finance (BSC)"
   ```

3. Dê ao agente apenas ferramentas de leitura HTTP. **Não** habilite shell com
   chave privada, wallet, `cast send`, `forge script` ou assinatura.

## Endpoints

- `https://gambiarra.finance/api/stats`
- `https://gambiarra.finance/agents.json`
- `https://gambiarra.finance/llms.txt`

## O que o agente faz

- Consulta `/api/stats` a cada 15 min.
- Compara invariantes (owner renunciado, emissão de 3 GAMB/bloco, 30 pools,
  LP duplicado nos pids 16 e 25, blockNumber avançando).
- Reporta anomalias no formato definido em `SOUL.md`.
- Nunca assina, paga ou move fundos.

## O que o agente não faz

- Deploy, transação, aprovação de token, x402.
- Interação com endereços fora do manifesto.
- Publicação de chave, seed ou `.env`.

## Desenvolvimento local

Se estiver rodando o site em dev com fork:

```bash
cd contracts && make fork          # terminal 1
cd web && npm run dev              # terminal 2
```

Aponte o agente para `http://localhost:3000/api/stats`. O campo `source` será
`fork` enquanto o Anvil estiver ativo — isso é esperado e não é mainnet.
