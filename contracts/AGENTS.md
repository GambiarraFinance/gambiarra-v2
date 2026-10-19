# AGENTS.md — contratos

Leia o [`AGENTS.md`](../AGENTS.md) da raiz primeiro. Este arquivo cobre apenas a
camada Solidity.

## Contexto

A v2 é uma camada **satélite** sobre o MasterChef legado da Gambiarra Finance na
BSC. O MasterChef (`0x77c1618248358f92Cb144269790103e67378A550`) tem
`owner() == 0x0` e é imutável. Nunca proponha alterá-lo, migrá-lo ou fazer
`delegatecall` nele.

Contratos:

| Arquivo | Papel |
| --- | --- |
| `src/GambVault.sol` | ERC4626 auto-compounder, stake no pool 25 |
| `src/GambTwapOracle.sol` | TWAP GAMB/WBNB + fair LP value |
| `src/GambLendingPool.sol` | lending isolado de WBNB, colateral em shares |
| `src/GambLeverageZap.sol` | abre/fecha alavancagem via flash swap Pancake V2 (WBNB/BUSD) |

Venue (imutável, verificada on-chain): o par GAMB/WBNB é um par **PancakeSwap V1**
(factory `0xBCfCcbde45cE874adCB698cC183deBcF17952812`), então o router do deploy é o
**V1** Router02 `0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F`. O Router V2
`0x10ED43C7…` **não roteia** este par: a factory V2 devolve `address(0)` e todo
`addLiquidity` reverte. O par de flash do zap é do V2 de propósito — a fee de 0,25%
dele é a que o zap assume.

## Invariantes

1. **ERC4626 com virtual shares/assets.** A proteção contra inflação de shares é
   obrigatória. Teste: doação direta antes do primeiro depósito não deve roubar
   valor de quem deposita depois.
2. **Saques nunca pausáveis.** Depósitos podem ser pausados; `withdraw`/`redeem`
   não. Não adicione `whenNotPaused` neles.
3. **Contabilidade de shares.** `totalAssets()` deve usar o valor real do pool,
   não um contador que possa dessincronizar. `accrueInterest()` antes de qualquer
   mudança de dívida no lending.
4. **LTV e liquidação.** Default 40% LTV / 50% threshold. Liquidação é
   permissionless. Não adicione allowlist nem bônus de liquidação acima do
   configurado. **Uma liquidação quita no máximo 50% da dívida**
   (`MAX_CLOSE_FACTOR_BPS`): quem liquida precisa repetir em rodadas até a
   posição ficar saudável, e a posição fica saudável antes disso (o bônus
   desalavanca). Posições com dívida abaixo de `DUST_DEBT` são liquidadas
   em uma chamada só, para o close factor nunca deixar dívida irrecuperável.
5. **Oráculo falha fechado.** Preço velho/insuficiente reverte. Nunca use spot
   como fallback silencioso. A janela mínima é 30 min e o fair value do LP é
   geométrico.
6. **Alavancagem.** O teto do zap é derivado de `lendingPool.maxLtvBps()` com
   margem de 10%. Não volte para 3x fixo.
7. **Sem proxy, sem upgrade, sem `delegatecall`.** Contratos imutáveis.
8. **`evm_version = "paris"`.** BSC historicamente rejeita `PUSH0`. Não mude sem
   validar em testnet.
9. **Pragma exato `0.8.26`.** Sem ranges.
10. **Checks-effects-interactions** em toda função que move fundos; use
    `ReentrancyGuard` onde houver callback externo (flash swap, MasterChef).
11. **Venue do par.** O par GAMB/WBNB é PancakeSwap **V1**. Nunca aponte o
    deploy para o Router V2 — reverte. Ver `script/DeployLib.sol`
    (`LegacyAddresses`).
12. **O oráculo precisa de keeper.** O par está dormente, então a janela TWAP só
    anda com `GambTwapOracle.poke()`. Sem um keeper dando poke a cada 30–120 min,
    o preço envelhece e o lending pool para de emprestar.

## Testes

```bash
forge fmt
forge fmt --check
forge test -vvv
forge test --match-contract GambLegacyForkTest -vvv   # precisa de BSC_RPC_URL
make fork-test     # invariantes do legado
make fork-test-v2  # a v2 inteira contra a BSC real
```

> Os fork tests fixam o bloco, então precisam de um RPC **archive**. Os
> `bsc-dataseed` públicos são podados e respondem "missing trie node" para
> estado histórico; `https://bsc-mainnet.public.blastapi.io` funciona. O bloco
> pode ser trocado com `BSC_FORK_BLOCK`.

- Adicione teste para toda mudança de comportamento, especialmente falhas
  (revert esperado), limites e aritmética.
- Use mocks em `test/mocks/` e interfaces em `src/interfaces/` para isolar.
- O fork test (`test/GambLegacy.fork.t.sol`) valida os fatos do legado e é
  pulado no CI quando `BSC_RPC_URL` não existe.
- `contracts/lib/` é vendorizado (forge-std + OpenZeppelin). Não edite.

## Segurança

- Rode Aderyn/Slither em mudanças que tocam fundos, shares, juros, LTV,
  liquidação ou oráculo. Atualize `AUDIT.md` com o triage.
- Não faça deploy em mainnet. Deploy em testnet só com confirmação explícita.
- Nunca commite chave privada, mnemônico ou `.env`.

## Commits

Autor `codingsh <codingsh@pm.me>`, sem `Co-authored-by`. Conventional Commits em
português. Não use `git add -A` se houver trabalho de outra sessão no tree.
