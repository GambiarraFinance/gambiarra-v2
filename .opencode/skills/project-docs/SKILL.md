---
name: project-docs
description: Use when documenting the gambiarra-v2 project — writing or updating README.md, contracts/AUDIT.md, SECURITY.md, AGENTS.md, agents/README.md, or the agent-facing endpoints (/llms.txt, /agents.json, /api/stats). Encodes the documentation doctrine: how a fact gets verified, the difference between an invariant and a snapshot, the shape of a finding entry, and the pass procedure. Trigger on "documentar", "documentação", "README", "AUDIT.md", "AGENTS.md", "SECURITY.md", "llms.txt", "agents.json".
---

# Documentar o gambiarra-v2

Este projeto é público, de código aberto, e opera sobre um contrato legado imutável que
ninguém pode corrigir. A documentação é parte do produto: ela é o que um agente lê antes de
agir, e um agente que lê errado age errado.

## O conjunto de documentos

| Documento | Para quem | Regra |
| --- | --- | --- |
| `README.md` (raiz) | gente e agentes | o ponto de entrada: o que é, o estado on-chain, a arquitetura, as premissas de confiança, a auditoria, o toolchain, **e o que ainda não é verdade** |
| `contracts/AUDIT.md` | quem vai implantar | o triage das ferramentas estáticas e os riscos aceitos |
| `SECURITY.md` | quem quer reportar bug | política de disclosure |
| `AGENTS.md` (raiz) e `contracts/AGENTS.md` | agentes de código | o contrato do repo: mapa, comandos, invariantes, o que não se faz |
| `agents/README.md` | agentes | índice do material para agentes |
| `web/README.md`, `contracts/README.md` | quem vai rodar | build e deploy |
| `/llms.txt`, `/agents.json`, `/api/stats` | agentes em runtime | o mesmo dado da visão humana, em máquina |

`CLAUDE.md`, `.cursor/`, `.windsurfrules` e `.github/copilot-instructions.md` são o mesmo
conteúdo do `AGENTS.md` em formatos de harness diferentes. Ao mudá-lo, mude todos — ou
aponte para a fonte única.

## Doutrina

### 1. Verificar ou omitir

Nenhuma linha pode afirmar algo que você não verificou agora. Nada de "deve continuar
funcionando", "provavelmente", "parece correto". Se você não rodou o comando nem leu o
código, a linha não entra.

Para fato on-chain, verifique com `cast` e **cite o bloco**:

```bash
RPC="https://bsc-mainnet.public.blastapi.io"   # endpoint ARCHIVE; os dataseed são podados
cast call $MC "poolInfo(uint256)(address,uint256,uint256,uint256)" 25 --rpc-url $RPC
cast block latest --rpc-url $RPC --field timestamp
```

Para comportamento, verifique com o código ou com o teste:

```bash
cd contracts
forge build && forge test -vvv
BSC_RPC_URL="https://bsc-mainnet.public.blastapi.io" forge test --match-contract GambV2ForkTest -vvv
cd web && npm run lint && npm run build
```

### 2. Invariante não é snapshot

A distinção mais importante deste projeto, porque o dado on-chain se move e a documentação
não pode fingir que não.

**INVARIANTE** — verdadeiro para sempre, porque a causa é imutável. Vai para `AGENTS.md`
como regra:
- o `owner()` do MasterChef é `0x0` — renunciado, imutável
- o LP GAMB/WBNB é um par **PancakeSwap V1** — a factory dele é imutável
- o mesmo LP está nos pools **16 e 25** — fixado no contrato legado
- `GambTwapOracle` falha fechado: preço velho reverte, nunca cai para spot
- saque nunca é pausável; deposital é

**SNAPSHOT** — se move. Vai para o README/AUDIT com bloco e data, nunca vira regra:
- `totalAllocPoint`, `allocPoint` por pool, TVL, saldos, `totalSupply`
- o valor de `totalAllocPoint` já mudou desde a primeira medição: um teste que fixava
  `2.56e30` quebrou sozinho. O que importa é a invariante ("é gigantesco, ~1e30"), não
  o número.

Regra prática: se o valor pode mudar sem que ninguém toque no código, ele é snapshot.

### 3. Achado sem teste não é achado documentado

Toda entrada de bug ou risco leva o nome do teste que o trava. Sem o nome do teste, o
achado é folclore — a próxima pessoa "corrige" e reintroduz.

Forma de uma entrada em `contracts/AUDIT.md`:

```
| # | Sev | Local | Achado | Correção |
```

E para um bug real, o texto precisa de: **sintoma** (o quebreaks, com o erro literal),
**causa raiz** (com os números), **fix**, e **teste de regressão** (nome).

O exemplo que definiu o padrão:

> **Sintoma:** `repay()` reverte com `panic 0x11` após qualquer accrual — a dívida
> ficava impagável. **Causa:** `totalBorrows` crescia por `rate × elapsed` (truncando
> `borrowsPrior * rate / 1e18` em até 1 unidade, e o `elapsed` multiplicava o erro:
> 2.462.400 wei após 30 dias), enquanto a dívida real cresce pelo índice `p * I / I_i` —
> o total ficava abaixo da soma das dívidas e `totalBorrows -= repaid` dava underflow.
> **Fix:** o índice move primeiro e o agregado é escalado pelo mesmo ratio; a subtração
> virou saturante. **Teste:** `test_repayFullDebtAfterAccrualDoesNotUnderflow`.

### 4. Risco aceito é documento, não silêncio

Risco que ninguém corrigiu entra no doc com: o **cenário de exploração** (quem faz o quê,
com quais fundos, para extraer o quê), a **mitigação** ou o **motivo da aceitação** explícita,
e o **gatilho de reavaliação** (o que teria que mudar para o risco mudar de tamanho).

Exemplo do padrão:

> **Bad debt.** Se o valor do collateral colapsar mais rápido do que os liquidadores reagem,
> o protocolo fica com dívida ruim — absorvida pelos fornecedores, não pelo owner. Decisão
> de design, documentada no cabeçalho do `GambLendingPool`. Reavaliar se a TVL passar de
> um patamar em que a liquidação manual seja plausível.

### 5. O que não é verdade é o que mais importa

O README deste projeto é pré-deploy. Dizer isso com clareza é parte do documento, não
modéstia excessiva. Documente com o mesmo peso:
- nada foi implantado, nenhum fundo real está em risco
- não há auditoria externa; a auditoria interna é auto-revisão
- a capacidade de crédito é dust (a reserva WBNB do par é ~0,24 WBNB)
- o par é PancakeSwap **V1**, e o oráculo precisa de um `poke()` periódico para não
  envelhecer

O oposto — apresentar o protocolo como pronto — é um risco documentado esperando a
materializar.

### 6. A visão humana e a de máquina não divergem

`web/src/lib/protocol.ts` é a **fonte única** dos endereços e da leitura on-chain. `/llms.txt`,
`/agents.json` e `/api/stats` derivam dela. Se um número aparece no dashboard e no JSON,
eles vêm do mesmo lugar — nunca hardcodeados em dois lugares.

Ao documentar um endpoint, o formato é parte do contrato: `text/plain`, `application/json`,
`text/html`. E um endpoint só leitura não assina transação nem guarda chave.

### 7. Estilo

- **PT-BR** na prosa, **inglês** nos identificadores (nomes de função, evento, erro).
- Sem emoji. Sem Futurespeak. Sem "revolutionário", "poderoso", "sem precedentes".
- Tabelas para comparação, listas para sequência, prosa para o raciocínio.
- Markdown legível em texto puro: um `grep` por um termo tem que achar a frase.
- Frase curta. Se a frase tem duas vírgulas e um "que", reescreva.

## Como rodar uma passada

1. **Estabeleça os fatos.** Leia o código, rode os comandos, consulte a chain. Escreva os
   números num rascunho com o bloco de origem.
2. **Escolha o documento.** Um fato novo pode tocar vários: a invariante do router V1 vai
   para `README.md`, `AUDIT.md` e `AGENTS.md` ao mesmo tempo.
3. **Escreva.** Edite cirúrgico — preserve estrutura, voz e ordem do documento. Prefira
   remover uma linha obsoleta a inventar uma nova. Não promova uma observação pontual a
   regra permanente.
4. **Confira o drift:** todo caminho citado existe; todo comando roda; todo número bate
   com a medição; toda invariante ainda vale no código.
5. **Reporte:** o que mudou, com o antes e o depois, e o que você não conseguiu verificar.

Ao final, sempre rode:

```bash
cd contracts && forge fmt --check && forge test -vvv
cd web && npm run lint && npm run build
```

## Onde o fork muda a documentação

O que só aparece contra a mainnet real, e que a documentação precisa registrar:

- **o par é V1** — a factory V2 devolve `address(0)`, então o router V2 reverteria em
  todo `addLiquidity`
- **a fee real do par é 20 bps** — medida, não presumida
- **o par está dormente** — o acumulador de preço não anda sem um `poke()`
- **o drift de truncamento** entre duas fórmulas matematicamente iguais — invisível para
  análise estática e para mock com números redondos
- **o Multicall3 da BSC executa como ele mesmo** — então nada que dependa da identidade do
  usuário pode ser agregado

Qualquer descoberta nova entra no swarm (beads) **e** no documento correspondente. Uma
descoberta que existe só num bead morre com a sessão.

## Não fazer

- Não documentar comportamento que você não executou.
- Não congelar snapshot em regra.
- Não esconder bug conhecido atrás de linguagem neutra.
- Não reescrever um documento inteiro quando o problema é uma linha.
- Não commitar. Devolva o diff proposto e deixe a decisão de commit para quem coordena.
