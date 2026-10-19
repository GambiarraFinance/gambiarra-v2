# Gambiarra Finance — web

Landing page, dashboard e endpoints agent-first do Gambiarra Finance v2.

Stack: **Next.js 16** (App Router, Cache Components) · **React 19** · **Tailwind CSS 4** · **viem 2** · **Three.js** (hero 3D).

## Rodando

```bash
npm install
cp .env.example .env.local   # opcional
npm run dev
```

Produção:

```bash
npm run build
npm run lint
npm start
```

O CI usa `npm install --no-audit --no-fund` (não `npm ci`) por causa das
dependências opcionais `@emnapi/*` no Linux.

## Fork da BSC em dev

Em `next dev`, o app tenta primeiro um fork local da BSC em
`http://127.0.0.1:8545` (chain id 56) e só cai para RPC público se o Anvil não
estiver rodando. Produção nunca tenta o fork.

```bash
# terminal 1
cd ../contracts && make fork

# terminal 2
cd web && npm run dev
```

Variáveis:

| Variável | Uso |
| --- | --- |
| `BSC_FORK_RPC_URL` | sobrescreve a URL do fork (padrão `http://127.0.0.1:8545`) |
| `USE_BSC_FORK=0` | desativa o fork mesmo em dev |
| `BSC_RPC_URL` | RPC dedicado do servidor (fallback para os públicos) |
| `NEXT_PUBLIC_RPC_URL` | RPC usado pelo browser no `WalletPanel` |
| `NEXT_PUBLIC_SITE_URL` | URL canônica/SEO |

## Estrutura

| Caminho | O que é |
| --- | --- |
| `src/app/page.tsx` | Landing (hero 3D, legado, stack, agentes, segurança) |
| `src/app/dashboard/page.tsx` | Estado on-chain do MasterChef legado + carteira |
| `src/app/llms.txt/route.ts` | Contexto em texto puro para LLMs |
| `src/app/agents.json/route.ts` | Manifesto legível por máquina |
| `src/app/api/stats/route.ts` | Estado on-chain em JSON |
| `src/app/sitemap.ts` / `robots.ts` | SEO |
| `src/app/opengraph-image.tsx` / `apple-icon.tsx` | Imagens geradas dinamicamente |
| `src/components/HeroScene.tsx` | Chinelo 3D em Three.js (com fallback SVG) |
| `src/components/WalletPanel.tsx` | Leitura de saldos/LP via viem, client-side |
| `src/lib/protocol.ts` | Endereços, RPC, leitura do MasterChef via viem |
| `src/lib/format.ts` | Formatação numérica pt-BR com bigint (half-up) |

## Leitura on-chain

`src/lib/protocol.ts` lê o MasterChef legado com **viem**, sem indexer e sem API
key. A ordem dos candidatos é:

1. fork local (somente em dev)
2. `BSC_RPC_URL` + RPCs públicos
3. snapshot auditado (`source: "fallback"`)

`/api/stats` e `/agents.json` expõem `source` (`fork` | `rpc` | `fallback`).
Números brutos são strings inteiras em wei; os campos `*Formatted` são apenas
para exibição e usam `src/lib/format.ts` (bigint, arredondamento half-up,
vírgula decimal e ponto de milhar).

## Endpoints

- `/llms.txt` — `text/plain`
- `/agents.json` — `application/json` (schema 1.1)
- `/api/stats` — `application/json`
- `/dashboard` — `text/html`

Use `<a>` (não `next/link`) para essas rotas cruas: prefetch de RSC não se aplica.

Documentação completa do projeto: [`../README.md`](../README.md).
Contexto para agentes: [`../AGENTS.md`](../AGENTS.md).
