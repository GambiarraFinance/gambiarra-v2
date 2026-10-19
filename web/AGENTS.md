# AGENTS.md — web

Leia o [`AGENTS.md`](../AGENTS.md) da raiz primeiro. Este arquivo cobre apenas o
app Next.js.

## Contexto

- Next.js 16 + React 19 + Tailwind 4 + viem 2 + Three.js.
- Server Components por padrão; `WalletPanel` é o componente cliente.
- Leitura on-chain exclusivamente via `src/lib/protocol.ts` (viem).
- Números formatados exclusivamente via `src/lib/format.ts` (bigint, half-up, pt-BR).
- Rotas cruas (`/llms.txt`, `/agents.json`, `/api/stats`) usam `<a>`, não `next/link`.
- `THREE.Timer` no hero; `THREE.Clock` está deprecado.

## Fork em dev

`next dev` tenta `http://127.0.0.1:8545` (chain id 56) antes do RPC público.
Suba o fork em outro terminal com `cd ../contracts && make fork`. Desative com
`USE_BSC_FORK=0`; sobrescreva a URL com `BSC_FORK_RPC_URL`. Produção nunca tenta
o fork.

## Checks

```bash
npm install
npm run lint
npm run build
```

## Commits

Autor `codingsh <codingsh@pm.me>`, sem `Co-authored-by`.

<!-- BEGIN:nextjs-agent-rules -->

## This is NOT the Next.js you know

This version has breaking changes — APIs, conventions, and file structure may all differ from your training data. Read the relevant guide in `node_modules/next/dist/docs/` (resolved from this file's directory; in monorepos the `next` package may not be visible from the repo root) before writing any code. Heed deprecation notices.

This block is written and re-added by `next dev` — verify at `node_modules/next/dist/server/lib/generate-agent-files.js`. Removing it from a diff only re-creates the uncommitted change; committing it with your work keeps the tree clean.

<!-- END:nextjs-agent-rules -->
