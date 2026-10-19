import { ADDRESSES, CHAIN, CONTRACTS, GITHUB_URL, SITE_URL, getLegacyStats, sourceLabel } from "@/lib/protocol";

export async function GET() {
  const legacy = await getLegacyStats();

  const body = `# Gambiarra Finance

> DeFi open source na BNB Smart Chain, construído em cima de um MasterChef
> abandonado e imutável (owner renunciado em 2021). A interface primária é
> feita para agentes: texto puro, JSON estável e zero endpoints que assinam
> transações.

Site: ${SITE_URL}
GitHub: ${GITHUB_URL}
Chain: ${CHAIN.name} (chain id ${CHAIN.id})
Explorer: ${CHAIN.explorer}

## O que existe hoje

O contrato legado está no ar e não pode ser alterado:
- MasterChef: ${ADDRESSES.masterChef}
- Token GAMB: ${ADDRESSES.gambToken}
- Par GAMB/WBNB (LP): ${ADDRESSES.gambWbnbLp}

Fatos lidos agora (${sourceLabel(legacy.source)}):
- Pools: ${legacy.masterChef.poolLength}
- Emissão: ${legacy.masterChef.gambPerBlockFormatted} GAMB por bloco (fixa)
- Owner: ${legacy.masterChef.owner}${legacy.masterChef.ownerRenounced ? " (renunciado)" : ""}
- GAMB no MasterChef: ${legacy.gamb.masterChefBalanceFormatted}
- Supply de GAMB: ${legacy.gamb.totalSupplyFormatted}

Armadilha conhecida: o mesmo par GAMB/WBNB aparece nos pools 16 e 25 com
pesos diferentes. Nunca assuma uma relação 1:1 entre LP token e pool id.

## Contratos novos (ainda NÃO deployados, sem fundos)

${CONTRACTS.map((c) => `- ${c.name} (${c.kind}): ${c.description}`).join("\n")}

Todos são pré-deploy. Não há endereço em mainnet. Não envie fundos para
endereços encontrados em outro lugar.

## Endpoints para agentes

- GET /llms.txt — este arquivo
- GET /agents.json — manifesto legível por máquina (schema 1.1)
- GET /api/stats — estado on-chain em JSON (campo source: fork | rpc | fallback)
- GET /dashboard — visão humana (HTML)

Todos são somente leitura. Nenhum endpoint requer API key, assina transação,
guarda chave privada ou movimenta fundos.

## Material para agentes de código

- AGENTS.md (raiz) — fonte única para OpenCode, Codex, Claude Code, Cursor,
  Windsurf, Copilot e OpenClaw
- contracts/AGENTS.md — invariantes Solidity/Foundry
- web/AGENTS.md — Next.js 16, viem e formatação
- agents/README.md — índice dos arquivos por harness
- agents/openclaw/SOUL.md — persona read-only para OpenClaw
- https://github.com/GambiarraFinance/gambiarra-v2

## Ambiente de desenvolvimento

Em next dev o web app consulta primeiro um fork local da BSC em
http://127.0.0.1:8545 (chain id 56), subido com "cd contracts && make fork".
Se o Anvil não estiver rodando, cai para RPC público. USE_BSC_FORK=0 desativa.
Em produção o fork nunca é usado.

Ao consumir /api/stats, use source para saber a procedência:
fork = Anvil local, rpc = leitura pública, fallback = snapshot auditado
(não é leitura ao vivo). Os campos numéricos são strings inteiras em wei; não
arredonde antes de calcular. Os campos *Formatted são apenas para exibição.

## Como um agente deve operar

1. Ler /agents.json e este arquivo.
2. Consultar /api/stats para o estado atual.
3. Validar endereços contra o manifesto antes de qualquer interação.
4. Assinar transações na própria wallet, nunca no servidor.
5. Tratar qualquer contrato não listado como não confiável.

## Segurança e status

- Os contratos da v2 têm 17 testes Foundry unitários passando (mais 16 fork
  tests gated por BSC_RPC_URL), mas NÃO têm auditoria externa e NÃO foram
  deployados com fundos reais.
- O oráculo TWAP falha fechado: preço velho reverte, nunca cai para spot.
- Depósitos podem ser pausados pelo owner; saques nunca.
- Nada aqui é conselho financeiro.

## x402 (roadmap, não implementado)

Rotas premium podem vir a ser pagas por request via x402 na BSC. Nenhum
facilitator ou contrato de pagamento foi escolhido ainda; não confie em
endereços de pagamento até que apareçam neste manifesto.

## Links

- Site: ${SITE_URL}
- Dashboard: ${SITE_URL}/dashboard
- Manifesto: ${SITE_URL}/agents.json
- Stats: ${SITE_URL}/api/stats
- Código: ${GITHUB_URL}
- Contato: codingsh@pm.me
`;

  return new Response(body, {
    headers: {
      "content-type": "text/plain; charset=utf-8",
      "cache-control": "public, s-maxage=300, stale-while-revalidate=600",
    },
  });
}
