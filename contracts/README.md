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

Estado atual: **17 testes unitários passando** (GambTwapOracle + GambLendingPool)
e **16 fork tests**, pulados quando `BSC_RPC_URL` não está definido.

## Fork da BSC

```bash
cp .env.example .env          # se existir; senão exporte BSC_RPC_URL na mão
make fork                     # anvil --fork-url $BSC_RPC_URL --chain-id 56
```

Em outro terminal:

```bash
make fork-test                # invariantes do legado + fluxo completo da v2
```

O alvo `fork-test` fixa `BSC_RPC_URL` no ambiente do `forge test`. Sem essa
variável, os 16 fork tests aparecem como `[SKIP]` — é o comportamento esperado
no CI.

## Makefile

| Alvo | O que faz |
| --- | --- |
| `make build` | `forge build` |
| `make test` | `forge test -vvv` |
| `make fmt` / `make fmt-check` | formata / valida formatação |
| `make fork` | sobe o Anvil com fork da BSC (chain id 56) |
| `make fork-test` | roda os fork tests contra a BSC real |
| `make clean` | `forge clean` |

Variáveis: `BSC_RPC_URL` (RPC de fork), `FORK_BLOCK` (fixa o bloco),
`ANVIL_FLAGS` (flags extras do Anvil).

## Deploy

Scripts em `script/` (`Deploy.s.sol`, `DeployLib.sol`). Eles são usados pelos
fork tests para provar que a stack se conecta ao venue real. **Não** há deploy
em mainnet. Qualquer deploy fora de uma fork local exige confirmação humana.

## Segurança

- `evm_version = "paris"` (BSC historicamente rejeita `PUSH0`).
- Sem proxy, sem upgrade, sem `delegatecall` na camada v2.
- Saques do vault nunca são pausáveis.
- O oráculo falha fechado: TWAP velho reverte, nunca cai para spot.
- Nunca commite chave privada, mnemônico ou `.env`.
