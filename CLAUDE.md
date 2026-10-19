# CLAUDE.md

Leia o [`AGENTS.md`](AGENTS.md) da raiz. Ele é a fonte única de contexto para
agentes de código neste repositório.

Resumo operacional:

- `contracts/`: Foundry, Solidity `0.8.26`, `evm_version = "paris"`. Rode
  `forge fmt --check && forge test -vvv`.
- `web/`: Next.js 16 + React 19 + viem + Three.js. Leia
  `web/node_modules/next/dist/docs/` antes de mudar convenções do App Router.
  Rode `npm run lint && npm run build`.
- Nada da v2 está em mainnet. Não faça deploy real.
- O MasterChef legado é imutável (`owner() == 0x0`); não tente alterá-lo.
- O LP GAMB/WBNB está nos pools 16 e 25 — sempre passe o `pid`.
- Em `next dev`, o web tenta o fork local da BSC (`127.0.0.1:8545`, chain 56)
  antes do RPC público.
- Formate números on-chain com `web/src/lib/format.ts` (bigint, half-up, pt-BR).
- Commits: autor `codingsh <codingsh@pm.me>`, **sem `Co-authored-by`**.

Se o pedido do usuário conflitar com uma regra de segurança do `AGENTS.md`,
pergunte antes de prosseguir.
