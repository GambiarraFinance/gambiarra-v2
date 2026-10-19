# Gambiarra Finance v2 — contratos

Camada satélite em Solidity `0.8.26` sobre o MasterChef legado da Gambiarra
Finance na BNB Smart Chain. O MasterChef tem `owner() == 0x0` e é imutável:
nada aqui tenta alterá-lo.

> [!WARNING]
> **Pré-deploy.** Nenhum contrato desta pasta está em mainnet. Não há auditoria
> externa. Não envie fundos. O deploy só deve acontecer em testnet com
> confirmação explícita e, em mainnet, após auditoria humana.

## Contratos

| Arquivo | Papel |
| --- | --- |
| `src/GambVault.sol` | ERC4626 auto-composto; deposita no pool 25 do MasterChef |
| `src/GambTwapOracle.sol` | TWAP GAMB/WBNB (fail-closed) e fair value do LP |
| `src/GambLendingPool.sol` | lending isolado em WBNB, colateral em shares do vault |
| `src/GambLeverageZap.sol` | abre/fecha alavancagem via flash swap Pancake V2 |

Interfaces mínimas ficam em `src/interfaces/`. Invariantes detalhados:
[`AGENTS.md`](AGENTS.md). Triage estático: [`AUDIT.md`](AUDIT.md).

## Requisitos

[Foundry](https://book.getfoundry.sh/getting-started/installation). As
dependências (`forge-std` e OpenZeppelin) estão vendorizadas em `lib/`, sem
submodules.

## Build e testes

```bash
forge build
forge test -vvv
forge fmt --check
```

Estado atual: **54 testes locais passando** (GambTwapOracle, GambLendingPool,
GambVault, GambLeverageZap e os invariantes com fuzzer) e **29 fork tests**
(GambV2ForkTest + GambLegacyForkTest), pulados quando `BSC_RPC_URL` não está
definido.

## Fork da BSC

```bash
cp .env.example .env          # se existir; senão exporte BSC_RPC_URL na mão
make fork                     # anvil --fork-url $BSC_RPC_URL --chain-id 56
```

Em outro terminal:

```bash
make fork-test                # invariantes do MasterChef legado
make fork-test-v2             # a v2 ponta a ponta (deploy + vault + lending + zap)
```

Os alvos fixam `BSC_RPC_URL` no ambiente do `forge test`. Sem essa variável, os
29 fork tests aparecem como `[SKIP]` — é o comportamento esperado no CI. Eles
fixam o bloco, então precisam de um nó **archive** (os `bsc-dataseed` públicos
são podados e respondem "missing trie node").

## Makefile

| Alvo | O que faz |
| --- | --- |
| `make build` | `forge build` |
| `make test` | `forge test -vvv` |
| `make fmt` / `make fmt-check` | formata / valida formatação |
| `make fork` | sobe o Anvil com fork da BSC (chain id 56) |
| `make fork-test` | invariantes do MasterChef legado contra a BSC real |
| `make fork-test-v2` | a v2 inteira contra a BSC real |
| `make keeper` | uma passada do keeper: `poke()` no oráculo + `harvest()` do vault |
| `make clean` | `forge clean` |

Variáveis: `BSC_RPC_URL` (RPC de fork), `FORK_BLOCK` (fixa o bloco),
`ANVIL_FLAGS` (flags extras do Anvil). Para `make keeper`: `ORACLE_ADDRESS`,
`VAULT_ADDRESS` (opcional) e `KEEPER_PRIVATE_KEY`.

## Deploy

Scripts em `script/` (`Deploy.s.sol`, `DeployLib.sol`). Eles são usados pelos
fork tests para provar que a stack se conecta ao venue real. **Não** há deploy
em mainnet. Qualquer deploy fora de uma fork local exige confirmação humana.

## Keeper

`script/Keeper.s.sol` é uma passada **permissionless** (não precisa de chave
privilegiada; qualquer EOA com gas serve) que faz duas coisas independentes e
best-effort:

1. `GambTwapOracle.poke()` — renova a janela TWAP sem impacto de preço.
2. `GambVault.harvest(0, deadline)` — compõe as recompensas pendentes em mais LP.

O par GAMB/WBNB está dormente, então a janela TWAP só anda com `poke()`. Sem um
keeper rodando a cada 30–120 min, o preço envelhece além de `MAX_STALENESS` e o
lending pool recusa toda avaliação de colateral — os empréstimos param.

```bash
ORACLE_ADDRESS=0x… VAULT_ADDRESS=0x… KEEPER_PRIVATE_KEY=0x… \
  make keeper          # equivale a forge script script/Keeper.s.sol:Keeper --broadcast
```

Agende com cron/systemd timer. Um `TooSoon` do `poke()` (par tocado há menos de
30 min) é no-op, não incidente: o script loga e segue para o `harvest`.

## Segurança

- `evm_version = "paris"` (BSC historicamente rejeita `PUSH0`).
- Sem proxy, sem upgrade, sem `delegatecall` na camada v2.
- Saques do vault nunca são pausáveis.
- O oráculo falha fechado: TWAP velho reverte, nunca cai para spot.
- Nunca commite chave privada, mnemônico ou `.env`.
