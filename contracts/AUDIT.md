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

| Ferramenta | High | Medium | Low | Info |
| --- | --- | --- | --- | --- |
| Aderyn | 1 (falso positivo) | 0 | 2 | — |
| Slither | 0 | 0 | 0 | 23 |
| Foundry | 13 testes passando, 0 falhando | | | |

`forge fmt --check` também passa.

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

23 resultados, todos **INFO** (nenhum High/Medium). Categorias:

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
   esperado em lending. Sem ação.

## O que ainda falta

- Auditoria humana independente (contratada ou via bug bounty).
- Testes unitários de `GambVault` e `GambLeverageZap` com mocks de MasterChef,
  router e flash pair.
- Fork tests contra o estado real da BSC (pool 16/25, reserves reais).
- Fuzzing/invariant testing dos invariantes de solvência do lending pool.
- Revisão econômica: liquidez do par, profundidade para liquidar posições,
  comportamento do TWAP em volatilidade real.

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
