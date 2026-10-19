# Gambiarra Finance v2

> **DeFi de chinelo. Cérebro de agente.**
> Uma camada nova, open source, sobre um MasterChef abandonado na BNB Smart Chain.

Em 2021 o `MasterChef` da Gambiarra Finance teve o ownership renunciado. Ninguém
pode mudar pesos, emissão ou criar pools — e ele continua emitindo **3 GAMB por
bloco, para sempre**. A v2 não tenta alterar esse contrato: ela o trata como
infraestrutura pública imutável e constrói por cima um vault auto-composto, um
oráculo TWAP, um pool de lending isolado e um zap de alavancagem — com uma API
desenhada para agentes autônomos.

> [!WARNING]
> **Status: pré-deploy.** Nenhum contrato da v2 foi deployado, nenhum fundo real
> está em risco e não há auditoria externa concluída. Os 17 testes Foundry
> unitários (mais 16 fork tests) passam,
> mas isso não é uma garantia de segurança. Nada aqui é conselho financeiro.

---

## Por que isso existe

O protocolo legado tem uma assimetria rara:

- **Owner renunciado** (`0x000…000`): o MasterChef é imutável.
- **30 pools** ativos, mas **6 concentram quase toda a emissão**.
- O mesmo par **GAMB/WBNB aparece nos pools 16 e 25**, com pesos diferentes.
- TVL baixo nos pools relevantes: o incentivo continua lá, mas a infraestrutura
  de acesso (vault, crédito, alavancagem) nunca foi reconstruída.

A v2 é essa reconstrução. O contrato antigo é a base; o valor novo está na
camada de composição e na interface para agentes.

### Fatos verificados on-chain

Reconsultados na BSC mainnet via `cast`:

| pool id | LP token | `allocPoint` |
| --- | --- | --- |
| 16 | `0x62DCE0C4…10D5` | `1e29` |
| **25** | `0x62DCE0C4…10D5` | **`3e29`** |

O mesmo LP está nos dois pools e o **pool 25 paga 3x as emissões** do 16. É por
isso que o `pid` do vault é 25. Escolher 25 não é otimizar APY: é escolher entre
dois pesos do mesmo par — e nada impede alguém de stakear o mesmo LP também no
16, o que divide a emissão do 25 entre os dois.

Estado do par `0x62DCE0C4…10D5` (GAMB é `token0`, WBNB é `token1`):

| Métrica | Valor |
| --- | --- |
| Reserva GAMB | ~1.022.219 GAMB |
| Reserva WBNB | **~0,2366 WBNB** |
| `totalSupply` do LP | ~15.508,57 LP tokens |
| Atividade | sem transferência de LP para/do MasterChef nos últimos ~200.000 blocos |

O lado WBNB do par tem 0,24 WBNB de liquidez: mover o preço de GAMB ali é
barato. É por isso que a avaliação de collateral usa TWAP e nunca spot, e por
isso o LTV default é conservador (40% LTV, 50% threshold de liquidação).

## Arquitetura

```
LP GAMB/WBNB ──► GambVault (ERC4626) ──► MasterChef pool 25 (legado, owner 0x0)
                        │ shares
                        ▼
                 GambLendingPool ◄── fornecedores de WBNB
                        │ dívida
                        ▼
                 GambLeverageZap ──► flash swap Pancake V2
                        ▲
                 GambTwapOracle (TWAP 30 min + fair LP value)
```

| Contrato | Papel | Arquivo |
| --- | --- | --- |
| `GambVault` | ERC4626 auto-compounder sobre o pool 25 do MasterChef | [`contracts/src/GambVault.sol`](contracts/src/GambVault.sol) |
| `GambTwapOracle` | TWAP de GAMB/WBNB + fair value geométrico do LP | [`contracts/src/GambTwapOracle.sol`](contracts/src/GambTwapOracle.sol) |
| `GambLendingPool` | Lending isolado de WBNB com colateral em shares do vault | [`contracts/src/GambLendingPool.sol`](contracts/src/GambLendingPool.sol) |
| `GambLeverageZap` | Abre/fecha posição alavancada em uma transação | [`contracts/src/GambLeverageZap.sol`](contracts/src/GambLeverageZap.sol) |

### Decisões de design

- **Sem proxy, sem upgrade.** O que foi deployado é o que fica.
- **Sem custódia.** O zap não guarda posição entre transações; colateral e dívida
  ficam registrados no `GambLendingPool` sob o endereço do usuário.
- **Saque nunca pausa.** O owner pode pausar depósitos, nunca retiradas.
- **Oráculo fail-closed.** TWAP velho reverte; nunca cai silenciosamente para spot.
- **Virtual shares/assets** no lending pool para tornar o ataque de inflação de
  shares via doação economicamente inviável.
- **Alavancagem limitada pelo LTV real do pool**, com margem de segurança — não
  por um número mágico no zap.

## Segurança

Já implementado e coberto por testes:

- 17 testes Foundry unitários (`GambTwapOracle` + `GambLendingPool`) e 16 fork
  tests contra a BSC real (`GambLegacy` + `GambV2`), incluindo:
  - ataque de doação/inflação de shares;
  - borrow dentro e acima do LTV;
  - bloqueio de saque de colateral que quebra o LTV;
  - liquidação de posição subcolateralizada e rejeição de posição saudável;
  - accrual de juros ao longo do tempo, inclusive quitação total com poeira de
    arredondamento;
  - TWAP stale, atualização cedo demais e fair value com reservas desbalanceadas;
  - invariantes do MasterChef legado (owner renunciado, 3 GAMB/bloco, LP
    duplicado nos pids 16 e 25);
  - vault depositando/retirando do MasterChef real, harvest compondo e zap
    abrindo posição alavancada em uma transação.
- Limites duros em constantes: fee, LTV, threshold de liquidação, bônus e
  slippage.
- `GambLeverageZap` deriva o teto de alavancagem do `maxLtvBps()` do pool.

### Auditoria estática — Slither + Aderyn

As duas ferramentas rodam contra `contracts/src` (Slither 0.11.3, 100 detectors;
Aderyn 0.6.5, 87 detectors). A saída bruta é ruidosa — boa parte é falso positivo
neste código —, então cada achado foi triado contra o fonte. A tabela traz só os
**confirmados**, todos corrigidos.

| # | Sev | Local | Achado | Correção |
| --- | --- | --- | --- | --- |
| 1 | Alta | `GambLeverageZap` `_handleClose` | `removeLiquidity` chamado com `amountAMin = 0` e `amountBMin = 0` — o sandwich escolhia o split GAMB/WBNB da redemption, e o swap seguinte executava contra o pool já inclinado | Mínimos não-zero derivados do split proporcional de reservas do par, com o buffer de slippage |
| 2 | Alta | `GambLeverageZap` `_handleClose` | Retorno de `lendingPool.repay()` ignorado — `repay` limita o valor ao débito, então um juro acumulado entre o snapshot e o callback deixava a posição meio fechada, em silêncio | Post-condição explícita: `currentDebt(user) != 0` ⇒ `PositionNotFullyRepaid` |
| 3 | Média | `GambVault` `harvest` | `block.timestamp` como deadline de swap — não oferece proteção contra transação atrasada | Deadline fornecido pelo caller: `harvest(minLpOut, deadline)` |
| 4 | Média | `GambVault` `harvest` | Split com `toCompound == 1` ⇒ `half == 0` ⇒ o router revertia no swap de valor zero, **brickando `harvest()` para sempre** | `toCompound < 2` retorna 0 e emite o evento; o resto fica no vault e é compilado no próximo harvest |
| 5 | Média | `GambLendingPool` `accrueInterest` | Estado mudava sem evento — indexers e agents não tinham sinal on-chain de que a dívida cresceu | Evento `InterestAccrued(borrowIndex, totalBorrows, totalReserves, interestAccumulated)` |
| 6 | Média | `GambLendingPool` `liquidate` | `seizeValueInWbnb` truncava para baixo, shaving o bônus do liquidator | `Math.mulDiv(..., Rounding.Ceil)` — bônus nunca truncado; o nº de shares continua arredondando **para baixo** |
| 7 | Média | `GambLendingPool` `withdrawReserves` | Limitado só pelo reserve acumulado; como o mesmo WBNB pode estar emprestado, o saldo em caixa pode ser menor e a chamada revertia | Cap duplo: pelo reserve **e** pelo WBNB em caixa |
| 8 | Média | `rescueToken` (vault + zap) | Podia varrer o GAMB pendente (recompensa dos depositantes) e, no zap, LP/shares/WBNB/GAMB | `CannotRescueVaultAsset` / `CannotRescueProtocolAsset` |
| 9 | Média | `GambLendingPool` | Juros calculados com `x * rate * elapsed / 1e18` — overflow intermediário e precisão perdida a cada passo | `Math.mulDiv` com intermediário de 512 bits, truncando só no final |
| 10 | Baixa | `GambTwapOracle` | Não implementava `IGambTwapOracle` | `contract GambTwapOracle is IGambTwapOracle` |
| 11 | Baixa | `GambTwapOracle` `update` | Estado mudava sem evento | Evento `PriceUpdated(priceAverageWad, blockTimestampLast)` |
| 12 | Baixa | `GambVault` `_withdraw` | Parâmetro `owner` sombreava `Ownable.owner()` | Renomeado para `owner_` |
| 13 | Baixa | `GambVault` | `error NotExited()` declarado e nunca usado | Removido |
| 14 | Baixa | Todos | `pragma solidity ^0.8.26` (faixa aberta) | Fixado em `0.8.26`, igual ao `solc_version` do `foundry.toml` |

**Descartados como falso positivo** (documentados para o próximo pass): o
`STATICCALL` "reentrancy" do Aderyn H-1 (14 instâncias, todas chamadas `view`),
`require(x >= y)` misparseado como comparação de timestamp, `== 0` em `uint`
sinalizado como "strict equality perigoso", PUSH0 (a BSC suporta), pragma de
`lib/`, e "Centralization Risk" (aviso genérico — cada poder do owner foi
revisado à mão, abaixo).

### Premissas de confiança

| Contrato | Poder do owner | Toca dinheiro do usuário? |
| --- | --- | --- |
| `GambVault` | `setFeeRecipient`, `setPerformanceFeeBps` (≤10%), `setCallerIncentiveBps` (≤1%), `setSwapSlippageBps` (0.5–5%), `setDepositsPaused`, `emergencyExitMasterChef` | **Não.** Pode pausar entradas, nunca saques. `rescueToken` não alcança LP/GAMB/shares. |
| `GambLendingPool` | `setRiskParams` (com hard caps), `setInterestRateModel` (≤10%/ano base, ≤100%/ano mult), `setBorrowingPaused`, `withdrawReserves` | **Não.** `withdrawReserves` só alcança a receita do reserve factor, que já está **fora** da claim dos fornecedores (`_totalAssets = cash + totalBorrows - totalReserves`) — sacá-la não muda o que eles podem resgatar. |
| `GambLeverageZap` | `setSwapSlippageBps` (0.5–5%), `setOpeningPaused`, `rescueToken` | **Não.** `rescueToken` bloqueia LP, shares do vault, WBNB e GAMB. |

O owner é `Ownable2Step` (transferência em duas etapas), o que elimina o erro
clássico de mandar para o endereço errado. **Ainda não há timelock** — para
mainnet com TVL relevante, timelock no owner é a evolução natural deste design.

### Riscos que análise estática não resolve

1. **Bad debt.** Se o collateral colapsar mais rápido do que os liquidadores reagem,
   o protocolo fica com dívida ruim — absorvida pelos fornecedores, não pelo owner.
   Decisão de design, documentada no cabeçalho do `GambLendingPool`.
2. **Oracle stale ou manipulado.** A janela TWAP de 30 min e o limite de staleness de
   2h mitigam, não eliminam. O contrato reverte em vez de devolver preço chute
   (falha fechada).
3. **Pool fino e dormente.** Ver acima — 0,24 WBNB de liquidez no lado WBNB.
4. **Contrato legado.** O MasterChef é imutável e não pode ser pausado. Se ele travar,
   o vault só tem `emergencyExitMasterChef()`.

> Isto é uma auto-revisão interna, **não substitui uma auditoria profissional de
> terceiros** antes de fundos reais em risco.

Ainda **não** coberto / pendente:

- Auditoria externa independente.
- Testes unitários do `GambVault` e do `GambLeverageZap` (dependem de mocks de
  MasterChef/router/flash pair).
- Fork tests contra o estado real da BSC.
- Definição de facilitator/stablecoin para x402.

Veja [`contracts/AUDIT.md`](contracts/AUDIT.md) para os relatórios de Aderyn e
Slither com o triage de cada achado, e [`SECURITY.md`](SECURITY.md) para o
escopo e como reportar problemas.

## Agentes primeiro

A interface primária para agentes não é HTML:

| Endpoint | Formato | Descrição |
| --- | --- | --- |
| `/llms.txt` | `text/plain` | Contexto completo para LLMs: o que é, o que não fazer. |
| `/agents.json` | `application/json` | Manifesto com contratos, limites, endpoints e status. |
| `/api/stats` | `application/json` | Estado on-chain do MasterChef legado. |
| `/dashboard` | `text/html` | Visão humana dos mesmos dados. |

Todos são **somente leitura**. Nenhum endpoint assina transação, guarda chave
privada ou movimenta fundos. O agente assina na própria wallet.

### Material para agentes de código

| Harness | Entrada |
| --- | --- |
| OpenCode, Codex, OpenClaw | [`AGENTS.md`](AGENTS.md) |
| Claude Code | [`CLAUDE.md`](CLAUDE.md) → `AGENTS.md` |
| Cursor | [`.cursor/rules/gambiarra.mdc`](.cursor/rules/gambiarra.mdc) |
| Windsurf | [`.windsurfrules`](.windsurfrules) |
| GitHub Copilot | [`.github/copilot-instructions.md`](.github/copilot-instructions.md) |

O índice completo (incluindo a persona read-only do OpenClaw) está em
[`agents/README.md`](agents/README.md). A fonte única é o `AGENTS.md` da raiz.

## Rodando localmente

### Contratos

Requisitos: [Foundry](https://book.getfoundry.sh/).

```bash
cd contracts
forge build
forge test -vvv
forge fmt --check
make fork        # Anvil com fork da BSC (chain id 56), em outro terminal
make fork-test   # invariantes do legado contra a BSC real (precisa de BSC_RPC_URL)
```

Auditoria estática (Aderyn e Slither instalados localmente):

```bash
cd contracts
aderyn -o audit/aderyn-report.md
slither . --filter-paths "lib|test" --compile-force-framework foundry \
  > audit/slither-report.txt
```

O triage dos achados está em [`contracts/AUDIT.md`](contracts/AUDIT.md).

As dependências (`forge-std` e OpenZeppelin) estão vendorizadas em
`contracts/lib/`, então o build é reproduzível sem submodules.

### Web

Requisitos: Node.js 22+.

```bash
cd web
npm install
cp .env.example .env.local   # opcional
npm run dev
```

Em `next dev`, o app tenta primeiro o fork local da BSC em
`http://127.0.0.1:8545` (chain id 56) e cai para RPC público se o Anvil não
estiver rodando. Produção nunca usa o fork.

Build de produção:

```bash
npm run build
npm run lint
npm start
```

Variáveis de ambiente (todas opcionais):

| Variável | Padrão | Uso |
| --- | --- | --- |
| `NEXT_PUBLIC_SITE_URL` | `https://gambiarra.finance` | canonical, sitemap, OG |
| `BSC_RPC_URL` | RPCs públicos | leitura on-chain no servidor |
| `BSC_FORK_RPC_URL` | `http://127.0.0.1:8545` | URL do fork em dev |
| `USE_BSC_FORK` | habilitado em dev | `0` desativa o fork |
| `NEXT_PUBLIC_RPC_URL` | RPC público | leitura no browser (`WalletPanel`) |

## Roadmap

- [ ] Auditoria externa dos quatro contratos.
- [ ] Testes unitários de `GambVault` e `GambLeverageZap` com mocks (hoje a
      cobertura deles vem dos fork tests).
- [x] Fork tests contra a BSC mainnet (`GambLegacy` + `GambV2`, gated por `BSC_RPC_URL`).
- [ ] Deploy em testnet + dashboard lendo endereços reais.
- [ ] x402 na BSC para rotas premium — **somente após** confirmar facilitator,
      stablecoin e contrato de pagamento.
- [ ] Deploy em mainnet com caps iniciais conservadores.

## Licença

MIT — veja [`LICENSE`](LICENSE).

Autor: **codingsh** `<codingsh@pm.me>` · [github.com/GambiarraFinance](https://github.com/GambiarraFinance)
