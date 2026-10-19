# Gambiarra Finance v2 — contratos
#
# `make fork` sobe um Anvil com fork da BSC na chain id 56 (a mesma que o
# web app espera). Em outro terminal: cd web && npm run dev.

# Public BSC endpoints are usually PRUNED: they can serve the latest state but
# answer "missing trie node" for historical blocks. Fork tests that pin a block
# need an archive node.
BSC_RPC_URL ?= https://bsc-mainnet.public.blastapi.io
FORK_BLOCK ?=
ANVIL_FLAGS ?= --chain-id 56 --host 127.0.0.1 --port 8545

.PHONY: build test fmt fmt-check fork fork-test clean

build:
	forge build

test:
	forge test -vvv

fmt:
	forge fmt

fmt-check:
	forge fmt --check

# Fork local da BSC. Fixe um bloco com FORK_BLOCK=12345678 para reprodutibilidade.
fork:
	anvil --fork-url "$(BSC_RPC_URL)" $(if $(FORK_BLOCK),--fork-block-number $(FORK_BLOCK),) $(ANVIL_FLAGS)

# Testa os invariantes do MasterChef legado contra a BSC real.
fork-test:
	BSC_RPC_URL="$(BSC_RPC_URL)" forge test --match-contract GambLegacyForkTest -vvv

# Testa a v2 ponta a ponta contra a BSC real (deploy + vault + lending + zap).
# Precisa de um nó ARCHIVE, porque o bloco é fixado para reprodutibilidade.
fork-test-v2:
	BSC_RPC_URL="$(BSC_RPC_URL)" forge test --match-contract GambV2ForkTest -vvv

clean:
	forge clean
