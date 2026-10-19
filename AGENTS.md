# AGENTS.md — Gambiarra Finance v2

> Fonte única de contexto para agentes de código que trabalham neste repositório:
> OpenCode, Codex, Claude Code, Cursor, Windsurf, Copilot, OpenClaw e afins.
> Se algo aqui conflitar com um pedido do usuário, pergunte antes de quebrar uma
> regra de segurança.

## TL;DR

- Monorepo: `contracts/` (Foundry, Solidity 0.8.26, BSC) + `web/` (Next.js 16, React 19, viem, Three.js).
- **Nada da v2 está deployado.** Não há fundos reais. Não faça deploy em mainnet.
- O `MasterChef` legado é **imutável** (`owner() == 0x0`). Nunca tente alterá-lo; construa camadas por cima.
- O mesmo LP GAMB/WBNB está nos pools **16 e 25**. Sempre passe o `pid` explicitamente.
- Toda leitura on-chain no web usa **viem**. Em `next dev`, o app tenta primeiro um **fork local da BSC** (`http://127.0.0.1:8545`, chain id 56) e cai para RPC público se o Anvil não estiver rodando.
- Números exibidos são formatados em `web/src/lib/format.ts` com **bigint**, arredondamento half-up e separadores pt-BR. Nunca use `Number(bigint)` para valores on-chain.
- Commits: autor **`codingsh <codingsh@pm.me>`**, **sem `Co-authored-by`**.

## Mapa do repositório

```
contracts/
  src/                 contratos v2 (GambVault, GambTwapOracle, GambLendingPool, GambLeverageZap)
  src/interfaces/      interfaces mínimas (inclui IGambMasterChef)
  script/              Deploy.s.sol + DeployLib.sol (endereços verificados, wiring)
  test/                Foundry tests + mocks
  test/GambLegacy.fork.t.sol  invariantes do legado contra fork da BSC
  test/GambV2.fork.t.sol      a v2 ponta a ponta contra a BSC real
  test/mocks/          MockMasterChef, MockRouter, MockVault, MockOracle, MockFlashPair
  audit/               relatórios Aderyn/Slither
  AUDIT.md             triage dos findings (estáticos + do fork)
  Makefile             build/test/fmt/fork/fork-test/fork-test-v2
web/
  src/app/             App Router: landing, /dashboard, /llms.txt, /agents.json, /api/stats
  src/components/      HeroScene (Three.js), WalletPanel (viem)
  src/lib/protocol.ts  endereços, RPC, leitura do MasterChef via viem, contratos, endpoints
  src/lib/format.ts    formatação numérica pt-BR baseada em bigint
  src/lib/wallet?      (não existe: a lógica de wallet vive em WalletPanel)
.opencode/skills/project-docs/  doutrina de documentação do projeto
.github/workflows/ci.yml  Foundry + Next
```

## Comandos canônicos

Contratos (em `contracts/`):

```bash
forge build
forge test -vvv
forge fmt --check
make fork        # anvil --fork-url $BSC_RPC_URL --chain-id 56
make fork-test   # invariantes do MasterChef legado (precisa de BSC_RPC_URL)
make fork-test-v2  # a v2 inteira contra a BSC real
```

> Os fork tests fixam o bloco, então exigem um RPC **archive** — os
> `bsc-dataseed` públicos são podados e respondem "missing trie node" para
> estado histórico. `https://bsc-mainnet.public.blastapi.io` funciona.

Web (em `web/`):

```bash
npm install
npm run dev      # em dev, tenta o fork local primeiro
npm run lint
npm run build
```

O CI usa **npm** (`npm install --no-audit --no-fund`), não bun. `bun.lock` existe,
mas não é o package manager do CI.

## Contratos: invariantes que não podem quebrar

1. **`GambVault` é ERC4626 com virtual shares/assets.** Não remova a proteção
   contra inflação de shares. Teste doação direta + primeiro depositante.
2. **Saques nunca são pausáveis.** Depósitos podem ser pausados pelo owner.
   Não introduza `whenNotPaused` em `withdraw`/`redeem`.
3. **`GambLendingPool` é isolado em WBNB.** Colateral é share do vault; LTV
   default 40%, threshold 50%, buffers verificados nos setters.
4. **Liquidação é permissionless.** Não adicione allowlist de liquidantes.
5. **`GambTwapOracle` falha fechado.** Preço velho reverte; nunca cai para spot.
   A janela mínima é 30 min e o fair value do LP é geométrico.
6. **`GambLeverageZap` deriva o teto de alavancagem de `maxLtvBps()`** com margem
   de 10%. Não volte para um multiplicador fixo de 3x.
7. **`evm_version = "paris"`.** BSC historicamente rejeita `PUSH0`; não mude para
   `cancun`/`shanghai` sem validar em testnet.
8. **Pragmas exatos `0.8.26`.** Não use ranges flutuantes.
9. **Nada de `delegatecall`, proxies ou upgradeability** na camada v2.
10. **Não edite `contracts/lib/`** (forge-std + OpenZeppelin vendorizados) nem o
    contrato legado. Se precisar de uma interface nova, crie em `src/interfaces/`.
11. **O par GAMB/WBNB é PancakeSwap V1.** A factory dele é
    `0xBCfCcbde45cE874adCB698cC183deBcF17952812` e a factory V2 devolve
    `address(0)` para (WBNB, GAMB) — rotear pelo Router V2 reverte em todo
    `addLiquidity`. O deploy usa o V1 Router02 `0x05fF2B0D…`
    (`contracts/script/DeployLib.sol`). Fato permanente: a factory do par é
    imutável.
12. **O oráculo TWAP precisa de keeper.** O par está dormente, então a janela só
    anda com `GambTwapOracle.poke()` — sem impacto de preço, mas alguém tem que
    chamar. Sem isso o lending pool para de emprestar.

Antes de considerar uma mudança de contrato pronta:

```bash
cd contracts
forge fmt
forge fmt --check
forge test -vvv
```

Se a mudança move fundos, altera contabilidade de shares, juros, LTV, liquidação
ou oráculo: rode também Aderyn/Slither e atualize `contracts/AUDIT.md`.

## Web: arquitetura e regras

- **Next.js 16 tem breaking changes.** Leia `web/node_modules/next/dist/docs/`
  antes de mexer em App Router, route handlers ou convenções. O bloco
  `BEGIN:nextjs-agent-rules` em `web/AGENTS.md` é reescrito pelo `next dev`;
  não o remova.
- **Server Components por padrão.** `WalletPanel` é o único componente cliente
  que precisa de wallet; mantenha o resto no servidor.
- **viem é a única camada de chain.** Não adicione `ethers`, `web3` ou JSON-RPC
  manual. `getLegacyStats()` em `src/lib/protocol.ts` é o único leitor do
  MasterChef e já faz fallback fork → RPC público → snapshot auditado.
- **Fork em dev.** `FORK_ENABLED` é verdadeiro quando `NODE_ENV !== "production"`
  e `USE_BSC_FORK !== "0"`. `BSC_FORK_RPC_URL` sobrescreve a URL. Produção nunca
  tenta o fork. O `WalletPanel` usa a mesma ordem de candidatos no browser.
- **Formatação numérica.** Use `formatTokenAmount`, `formatCompactToken`,
  `formatScientific` e `formatIntegerPtBr` de `src/lib/format.ts`. Elas arredondam
  half-up, usam vírgula decimal e ponto de milhar, e não perdem precisão.
  `totalAllocPoint` é inteiro bruto: mostre com `formatScientific`.
- **Rotas cruas não são páginas.** `/llms.txt`, `/agents.json` e `/api/stats` são
  route handlers. Use `<a href>` (não `next/link`) para eles; prefetch de RSC
  quebra e gera warning.
- **Acessibilidade e responsivo.** Preserve `lang="pt-BR"`, skip link,
  `aria-label`s, foco visível e os breakpoints existentes. Teste 390px e 1440px.
- **Three.js.** Use `THREE.Timer` (não `THREE.Clock`, deprecado). O hero tem
  fallback SVG para `prefers-reduced-motion` e WebGL indisponível.

Antes de considerar uma mudança de web pronta:

```bash
cd web
npm run lint
npm run build
```

## Endpoints para agentes em runtime

Somente leitura, sem API key, sem assinatura de transação:

| Rota | Formato | Uso |
| --- | --- | --- |
| `/llms.txt` | `text/plain` | contexto para LLMs |
| `/agents.json` | `application/json` | manifesto com contratos, limites e status |
| `/api/stats` | `application/json` | estado on-chain + `source`/`fork` |
| `/dashboard` | `text/html` | visão humana |

Regras para qualquer agente que consuma esses endpoints:

1. Valide endereços contra `/agents.json`; trate qualquer endereço não listado
   como não confiável.
2. Use `source` (`fork` | `rpc` | `fallback`) para saber a procedência.
   `fallback` é snapshot auditado, não leitura ao vivo.
3. `totalAllocPoint`, `totalSupply` e saldos são strings inteiras (wei). Não
   arredonde antes de calcular; formate só na apresentação.
4. Não assine transações no servidor. Chaves privadas nunca entram no repo.
5. x402 é roadmap: nenhum facilitator, stablecoin ou endereço de pagamento foi
   definido. Não pague nada até o manifesto listar o endereço.

## Segurança

- Leia `SECURITY.md` antes de reportar ou corrigir vulnerabilidade.
- Não commite `.env`, chaves, mnemônicos, RPC com API key ou artefatos de build.
- Não rode `git add -A` às cegas: há sessões/arquivos em progresso.
- Não faça deploy em mainnet, não assine transações com fundos reais e não
  publique endereços de contrato que não existam.
- Auditoria externa humana ainda é obrigatória antes de mainnet.

## Git

```bash
git config user.name "codingsh"
git config user.email "codingsh@pm.me"
git commit -m "tipo(escopo): descrição"
```

- Autor exclusivo: `codingsh <codingsh@pm.me>`.
- **Proibido** `Co-authored-by` e trailers de coautoria.
- Commits em português, Conventional Commits (`feat`, `fix`, `docs`, `test`, `chore`).
- Antes de commitar: `git status`, `git diff`, e os checks acima.
- Se houver trabalho de outra sessão no working tree, não o inclua no seu commit.

## Definição de pronto

- [ ] `cd contracts && forge fmt --check && forge test -vvv`
- [ ] `cd web && npm run lint && npm run build`
- [ ] Nenhum segredo, endereço falso ou fundo real.
- [ ] Docs/agents atualizados se mudou comandos, rotas ou invariantes.
- [ ] Commit com autor `codingsh`, sem coautoria.

## Onde ler mais

- `README.md` — visão geral, arquitetura, fatos on-chain.
- `contracts/AUDIT.md` — triage Aderyn/Slither e riscos aceitos.
- `contracts/README.md` — detalhes de build e deploy.
- `web/README.md` — rotas, env e fork.
- `SECURITY.md` — política de disclosure.
- `agents/README.md` — índice do material para agentes.
- `.opencode/skills/project-docs/SKILL.md` — doutrina de documentação: como
  verificar um fato, invariante vs. snapshot, e o formato de uma entrada de
  achado. Use ao escrever ou revisar qualquer doc do projeto.
