# Auditoria e análise estática

> **Isto não é uma auditoria externa.** É o registro do que foi rodado, dos
> achados e do triage feito pelo autor. Nenhum contrato da v2 foi deployado e
> nenhum fundo real está em risco.

## Ferramentas e versões

| Ferramenta | Versão | Comando |
| --- | --- | --- |
| Foundry | `forge` (solc 0.8.26) | `forge build && forge test -vvv` |
| Aderyn | 0.6.5 | `aderyn -o audit/aderyn-report.md` |
| Slither | 0.11.3 | `slither . --filter-paths "lib\|test" --compile-force-framework foundry` |

Relatórios brutos:

- [`audit/aderyn-report.md`](audit/aderyn-report.md)
- [`audit/slither-report.txt`](audit/slither-report.txt)

## Resumo

Estado **final**, depois das correções:

| Ferramenta | High | Medium | Low | Info | Total |
| --- | --- | --- | --- | --- | --- |
| Aderyn | 1 (falso positivo) | 0 | 2 | — | 3 |
| Slither | 0 | 15 | 8 | 0 | 23 |
| Foundry | 17 unitários + 16 fork tests, 0 falhando | | | | |

`forge fmt --check` também passa.

> Nota de leitura: a saída de console do Slither rotula os grupos como
> `INFO:Detectors:`, que é o **nível de verbosidade** do console, não a
> severidade. A severidade por achado está no campo `impact` do JSON
> (`slither . --json ...`): Low 8, Medium 15, nenhum High. Os 15 Medium e os 8
> Low são os falsos positivos triados abaixo. **Nenhum achado real resta.**

## Achados confirmados e corrigidos

Estas correções foram aplicadas ao código; o detalhamento e o raciocínio
estão no README da raiz.

| # | Sev | Local | Achado | Correção |
| --- | --- | --- | --- | --- |
| 1 | Alta | `GambLeverageZap._handleClose` | `removeLiquidity` com `amountAMin = 0` e `amountBMin = 0` — o sandwich escolhia o split GAMB/WBNB da redemption, e o swap seguinte executava contra o pool já inclinado | Mínimos não-zero derivados do split proporcional de reservas do par (`_expectedLpSplit`), com o buffer de slippage do protocolo |
| 2 | Alta | `GambLeverageZap._handleClose` | Retorno de `lendingPool.repay()` ignorado — `repay` limita o valor ao débito, então um juro acumulado entre o snapshot e o callback deixava a posição meio fechada, em silêncio | Post-condição explícita: `currentDebt(user) != 0` ⇒ `PositionNotFullyRepaid` |
| 3 | Média | `GambVault.harvest` | `block.timestamp` como deadline de swap — não oferece proteção contra transação atrasada | Deadline fornecido pelo caller: `harvest(minLpOut, deadline)` |
| 4 | Média | `GambVault.harvest` | Split com `toCompound == 1` ⇒ `half == 0` ⇒ o router revertia no swap de valor zero, **brickando `harvest()` para sempre** | `toCompound < 2` retorna 0 e emite o evento; o resto fica no vault e é compilado no próximo harvest |
| 5 | Média | `GambLendingPool.accrueInterest` | Estado mudava sem evento — indexers e agents não tinham sinal on-chain de que a dívida cresceu | Evento `InterestAccrued(borrowIndex, totalBorrows, totalReserves, interestAccumulated)` |
| 6 | Média | `GambLendingPool.liquidate` | `seizeValueInWbnb` truncava para baixo, shaving o bônus do liquidator e deixando o protocolo short | `Math.mulDiv(..., Rounding.Ceil)` — bônus nunca truncado; o nº de shares continua arredondando **para baixo**, a favor do borrower |
| 7 | Média | `GambLendingPool.withdrawReserves` | Limitado só pelo reserve acumulado; como o mesmo WBNB pode estar emprestado, o saldo em caixa pode ser menor e a chamada revertia | Cap duplo: pelo reserve **e** pelo WBNB em caixa |
| 8 | Média | `rescueToken` (vault + zap) | Podia varrer o GAMB pendente (recompensa dos depositantes) e, no zap, LP/shares/WBNB/GAMB | `CannotRescueVaultAsset` / `CannotRescueProtocolAsset` |
| 9 | Média | `GambLendingPool` (juros) | `x * rate * elapsed / 1e18` — overflow intermediário possível e precisão perdida em cada passo | `Math.mulDiv` com intermediário de 512 bits, truncando só no final |
| 10 | Baixa | `GambTwapOracle` | Não implementava `IGambTwapOracle` | `contract GambTwapOracle is IGambTwapOracle` |
| 11 | Baixa | `GambTwapOracle.update` | Estado mudava sem evento | Evento `PriceUpdated(priceAverageWad, blockTimestampLast)` |
| 12 | Baixa | `GambVault._withdraw` | Parâmetro `owner` sombreava `Ownable.owner()` | Renomeado para `owner_` |
| 13 | Baixa | `GambVault` | `error NotExited()` declarado e nunca usado | Removido |
| 14 | Baixa | Todos | `pragma solidity ^0.8.26` (faixa aberta) | Fixado em `0.8.26`, igual ao `solc_version` do `foundry.toml` |

## Achados do fork contra a BSC real

A análise estática não alcança o que só aparece rodando os contratos contra a
mainnet. A suíte é `test/GambV2.fork.t.sol` (bloco pinado 128620982, `make
fork-test-v2`).

| # | Sev | Local | Achado | Correção |
| --- | --- | --- | --- | --- |
| F1 | **Bloqueante** | configuração de deploy | O par GAMB/WBNB é um par **PancakeSwap V1** (factory `0xBCfCcbde…`, `INIT_CODE_PAIR_HASH` `0xd0d4c4cd…`). A factory V2 devolve `address(0)` para (WBNB, GAMB), então rotear pelo Router V2 (`0x10ED43C7…`) **reverte em todo `addLiquidity`/`removeLiquidity`/swap** | Router V1 Router02 `0x05fF2B0D…`, com os quatro seletores do `IPancakeRouter02` verificados no bytecode. Endereços centralizados em `script/DeployLib.sol` (`LegacyAddresses`) |
| F2 | **Crítica** | `GambLendingPool.repay` / `.liquidate` | Revertiam com `panic 0x11` após qualquer accrual — a dívida ficava **impagável**. `totalBorrows` crescia por `rate × elapsed` (truncando `borrowsPrior * rate / 1e18` em até 1 unidade, e o `elapsed` multiplicava o erro: 2.462.400 wei após 30 dias), enquanto a dívida real cresce pelo índice `p * I / I_i` — o total ficava abaixo da soma das dívidas | O índice move primeiro e o agregado é escalado pelo mesmo ratio (`interestAccumulated = mulDiv(borrowsPrior, indexDelta, borrowIndex)`); a subtração virou saturante (`_decreaseTotalBorrows`). Regressão: `test_repayFullDebtAfterAccrualDoesNotUnderflow`, `test_liquidateFullDebtAfterAccrualDoesNotUnderflow` |
| F3 | **Alta** | `GambTwapOracle` | Cold-start: o par está dormente (54h38m sem toque) e num par V2 o acumulador só anda quando o par é tocado — `update()` revertia `TooSoon` para sempre e o lending pool nunca emprestaria | `poke()` permissionless: `pair.sync()` (avança o acumulador **sem impacto de preço**) e atualiza. Regressão: `test_fork_oracleStartsStaleBecauseThePairIsDormant` |
| F4 | Média | `GambTwapOracle.isStale` | Mediava a staleness contra o relógio do **par**, congelado num par dormente — servia preço de qualquer idade como fresco, o oposto do fail-closed prometido | Compara com `block.timestamp` |
| F5 | Média | Multicall3 (plataforma) | Na BSC o `aggregate` roda as inner calls com o **próprio Multicall** como `msg.sender`: allowance, aprovação de operator e abertura de posição não podem ser agregadas em nome do usuário | Não é corrigível no contrato — o caminho para 1 transação é autorização por assinatura (EIP-712). Regressão: `test_fork_multicallCannotOpenAPositionOnTheUsersBehalf` |
| F6 | Info | par GAMB/WBNB | A fee real de swap é **20 bps (0,2%)**, não 25 — medida no pool vivo, não presumida | O slippage default de 1,5% do vault cobre com folga. Regressão: `test_fork_gambWbnbPairSwapFeeIsWithinTheAssumedTolerance` |

> **Por que o F2 só apareceu no fork:** é um drift de truncamento entre duas
> fórmulas matematicamente idênticas. Nenhum analisador estático compara as duas,
> e um teste com mocks e números redondos (1e18, 30 dias) produz truncamentos
> simétricos e esconde o erro. O fork usa os juros reais do MasterChef legado.

## Triage — Aderyn

### H-1: Reentrancy — state change after external call (falso positivo)

O Aderyn marca 15 pontos onde um estado é alterado depois de uma chamada
externa. Os "external calls" apontados são, na prática:

- `wbnb.balanceOf(address(this))` — `view`, sem callback;
- `pair.token0()` / `pair.token1()` — `view`;
- `pair.getReserves()` — `view`;
- leituras de `poolInfo` / `userInfo` no construtor — sem reentrância possível.

Nenhum desses pontos transfere controle para um contrato não confiável. Além
disso, todas as entry points que movem fundos (`supply`, `redeem`,
`depositCollateral`, `withdrawCollateral`, `borrow`, `repay`, `liquidate`,
`openLeveragedPosition`, `closeLeveragedPosition`, `harvest`, `deposit`,
`withdraw`) usam `nonReentrant`. O callback do flash swap (`pancakeCall`) é
protegido por `msg.sender == flashPair` + `sender == address(this)`, e a função
externa que o dispara também é `nonReentrant`.

**Conclusão:** sem ação. Mantido como falso positivo documentado.

### L-1: Centralization risk (aceito, com escopo limitado)

Os contratos têm owner (`Ownable2Step`) para funções administrativas:

- `GambVault`: fee, incentivo de caller, slippage, pausar **depósitos**,
  `emergencyExitMasterChef`, `rescueToken`.
- `GambLendingPool`: parâmetros de risco, modelo de juros, pausar **empréstimos**,
  `withdrawReserves`.
- `GambLeverageZap`: slippage, pausar **abertura**, `rescueToken`.

Nenhum owner consegue bloquear saques, mover colateral de usuário ou trocar a
lógica de um contrato (não há proxy). O risco residual é aceito para esta fase
pré-deploy; o deploy deve usar multisig e, no caso do vault, renunciar ou migrar
para timelock antes de TVL relevante.

### L-2: Large numeric literal (estilo)

`10_000`, `30_000` etc. são mais legíveis que `1e4`/`3e4` em código de taxa.
**Sem ação.**

> L-2 (pragma não específico) e L-3 (PUSH0) da primeira execução foram
> corrigidos: todos os pragmas agora são `0.8.26` exato e `foundry.toml` usa
> `evm_version = "paris"`, evitando `PUSH0` em BSC.

## Triage — Slither

23 resultados, nenhum High. No JSON de severidade são 15 Medium e 8 Low, mas
todos caem em quatro categorias de falso positivo:

1. **Dangerous strict equality** (`== 0`, `elapsed == 0`): comparações
   intencionais para early-return em divisão/accrual. Sem ação.
2. **Unused return**: desestruturação de tuplas (`(,, shares) = ...`) e retornos
   de `addLiquidity`/`getReserves` que não são necessários. Sem ação. O caso do
   `lendingPool.repay` é intencional: o retorno é limitado pela dívida, e a
   pós-condição `currentDebt(user) == 0` imediatamente depois garante que a
   posição foi totalmente encerrada.
3. **Reentrancy (event after external call)**: eventos emitidos após chamadas
   externas, todos em funções `nonReentrant`; não há estado de fundos lido
   depois do evento. Sem ação.
4. **Block timestamp**: uso de `block.timestamp` para juros e deadlines,
   esperado em lending. Sem ação — `deadline < block.timestamp` é justamente o
   padrão correto de expiry, e `amount > totalReserves` nem é comparação de
   timestamp (o detector casa por vizinhança textual).

## O que ainda falta

- Auditoria humana independente (contratada ou via bug bounty).
- Testes unitários de `GambVault` e `GambLeverageZap` com mocks de MasterChef,
  router e flash pair. (O `GambVault` e o `GambLeverageZap` **estão** cobertos pelo
  fork test end-to-end, contra o MasterChef e o par reais — mas não por mocks.)
- Fuzzing/invariant testing dos invariantes de solvência do lending pool.
- Revisão econômica: liquidez do par, profundidade para liquidar posições,
  comportamento do TWAP em volatilidade real.
- Autorização por assinatura (EIP-712) no lending pool e no zap, para colapsar
  o fluxo de abertura em uma transação — ver F5.
- Um keeper de `poke()` rodando, ou o lending pool fica sem preço utilizável
  (ver F3).

## Reproduzindo

```bash
cd contracts
forge clean
forge build
forge test -vvv
forge fmt --check

aderyn -o audit/aderyn-report.md
slither . --filter-paths "lib|test" --compile-force-framework foundry
```
