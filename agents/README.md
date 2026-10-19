# Material para agentes

Este diretório é o índice do contexto que qualquer agente — de código ou de
runtime — deve ler antes de operar a Gambiarra Finance.

## Agentes de código

| Harness | Arquivo de entrada | Observação |
| --- | --- | --- |
| OpenCode | [`AGENTS.md`](../AGENTS.md) | lido automaticamente na raiz |
| Codex (OpenAI) | [`AGENTS.md`](../AGENTS.md) | lido automaticamente na raiz |
| Claude Code | [`CLAUDE.md`](../CLAUDE.md) | aponta para `AGENTS.md` |
| Cursor | [`.cursor/rules/gambiarra.mdc`](../.cursor/rules/gambiarra.mdc) | regra `alwaysApply` |
| Windsurf | [`.windsurfrules`](../.windsurfrules) | regras globais |
| GitHub Copilot | [`.github/copilot-instructions.md`](../.github/copilot-instructions.md) | instruções do repositório |
| OpenClaw | [`agents/openclaw/SOUL.md`](openclaw/SOUL.md) | persona de analista read-only |

**Fonte única:** `AGENTS.md` na raiz. Os outros arquivos são pontes curtas para
evitar divergência. Se uma regra mudar, mude primeiro no `AGENTS.md`.

## Agentes de runtime

A interface pública, somente leitura e sem API key:

- `GET /llms.txt` — contexto em texto puro.
- `GET /agents.json` — manifesto legível por máquina (schema 1.1).
- `GET /api/stats` — estado on-chain com `source` (`fork`/`rpc`/`fallback`).
- `GET /dashboard` — visão humana.

Regras rápidas:

1. Valide endereços contra `agents.json`.
2. Calcule com as strings inteiras (wei); formate só no fim.
3. Nunca assine transação no servidor nem envie chave privada.
4. `fallback` significa snapshot auditado, não leitura ao vivo.
5. x402 é roadmap sem facilitator/stablecoin/endereço definidos — não pague nada.

## OpenClaw

O perfil em [`agents/openclaw/SOUL.md`](openclaw/SOUL.md) descreve um agente
analista que monitora os endpoints acima e reporta anomalias sem mover fundos.
Veja [`agents/openclaw/README.md`](openclaw/README.md) para o setup.

## Desenvolvimento local

```bash
# contratos + fork da BSC
cd contracts && make fork        # terminal 1
cd contracts && make fork-test   # terminal 2 (opcional)

# web
cd web && npm run dev            # tenta o fork local primeiro
```

Em `next dev`, o web app usa `http://127.0.0.1:8545` (chain id 56) se o Anvil
estiver rodando; caso contrário cai para RPC público. Desative com
`USE_BSC_FORK=0`.
