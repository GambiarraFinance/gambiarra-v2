# Instruções para agentes de código

A fonte única de contexto é o [`AGENTS.md`](../AGENTS.md) na raiz. Leia antes de
editar qualquer arquivo.

Pontos que mais causam erro:

- **Não faça deploy em mainnet.** A v2 é pré-deploy, sem auditoria externa.
- **Não altere o MasterChef legado** (`0x77c1…A550`, owner `0x0`). Construa por cima.
- **LP GAMB/WBNB duplicado** nos pools 16 e 25: sempre passe o `pid` (o vault usa 25).
- **Solidity:** pragma exato `0.8.26`, `evm_version = "paris"`, sem proxy/upgrade,
  saques do vault nunca pausáveis.
- **Web:** Next.js 16 tem breaking changes — leia `web/node_modules/next/dist/docs/`.
  Use viem (não ethers/web3), `THREE.Timer` (não `Clock`) e `<a>` para rotas cruas
  (`/llms.txt`, `/agents.json`, `/api/stats`).
- **Números:** use `web/src/lib/format.ts`; nunca `Number(bigint)`.
- **Checks:** `cd contracts && forge fmt --check && forge test -vvv`;
  `cd web && npm run lint && npm run build`.
- **Commits:** autor `codingsh <codingsh@pm.me>`, sem coautoria.

Regras completas, arquitetura, endpoints e definição de pronto: `AGENTS.md`.
