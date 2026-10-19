# Gambiarra Finance — web

Landing page, dashboard e endpoints agent-first do Gambiarra Finance v2.

Stack: **Next.js 16** (App Router, Cache Components) · **React 19** · **Tailwind CSS 4** · **Three.js** (hero 3D).

## Rodando

```bash
npm ci
cp .env.example .env.local   # opcional
npm run dev
```

Produção:

```bash
npm run build
npm run lint
npm start
```

## Estrutura

| Caminho | O que é |
| --- | --- |
| `src/app/page.tsx` | Landing (hero 3D, legado, stack, agentes, segurança) |
| `src/app/dashboard/page.tsx` | Estado on-chain do MasterChef legado |
| `src/app/llms.txt/route.ts` | Contexto em texto puro para LLMs |
| `src/app/agents.json/route.ts` | Manifesto legível por máquina |
| `src/app/api/stats/route.ts` | Estado on-chain em JSON |
| `src/app/sitemap.ts` / `robots.ts` | SEO |
| `src/app/opengraph-image.tsx` | Imagem OG gerada dinamicamente |
| `src/components/HeroScene.tsx` | Chinelo 3D em Three.js (com fallback SVG) |
| `src/lib/protocol.ts` | Endereços, constantes e leitura via RPC |

## Leitura on-chain

`src/lib/protocol.ts` lê o MasterChef legado direto por JSON-RPC público, sem
indexer e sem API key. Se todos os RPCs falharem, a página degrada para um
snapshot auditado em vez de mostrar zeros.

Configuração opcional: `NEXT_PUBLIC_SITE_URL` e `BSC_RPC_URL` (veja
`.env.example`).

## Endpoints

- `/llms.txt` — `text/plain`
- `/agents.json` — `application/json`
- `/api/stats` — `application/json`
- `/dashboard` — `text/html`

Documentação completa do projeto: [`../README.md`](../README.md).
