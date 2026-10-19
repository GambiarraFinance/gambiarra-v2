# Economia do protocolo

> Todos os números abaixo são **medidos on-chain** (BSC mainnet, fork no bloco
> 128620982) e no **trace real de execução** dos testes. Nada é estimativa.
> Método para reproduzir no fim do documento.

## 1. A base medida

| Métrica | Valor | Como foi medido |
| --- | --- | --- |
| Tempo de bloco | **0,45 s** → 192.000 blocos/dia | `cast block` em duas alturas separadas por 2.000 blocos |
| Emissão do MasterChef | 3 GAMB/bloco = **576.000 GAMB/dia** (30 pools) | `gambPerBlock()` |
| Share do pool 25 | 3e29 / 2,5578e30 = **11,7287%** | `poolInfo(25)` e `totalAllocPoint()` |
| Emissão do pool 25 | **67.557 GAMB/dia** | derivado |
| Reservas do par GAMB/WBNB | 1.022.191.083 GAMB \| **0,23656 WBNB** | `getReserves()` |
| Preço implícito do GAMB | **2,3143e-10 WBNB** (R$ 0,00000069) | reservas |
| LP em circulação | 15.508,57 tokens | `totalSupply()` |
| Valor do par inteiro | 0,4731 WBNB (**R$ 1.419**) | 2 × reserva WBNB (média geométrica) |
| Valor por LP | 3,0507e-5 WBNB | derivado |
| Gas do `harvest` | **412.529** gas → R$ 0,0619 @ 0,05 gwei | trace do fork test |
| Gas do `poke` | **75.111** gas → R$ 0,0113 @ 0,05 gwei | trace do fork test |
| Gas do `deposit` | **232.695** gas → R$ 0,0349 @ 0,05 gwei | trace do fork test |

## 2. A estrutura que decide tudo

A emissão é **fixa**: 3 GAMB/bloco, para sempre, independentemente de quantas pessoas
usam o protocolo. Três consequências:

1. **O APY é inversamente proporcional à TVL.** A mesma emissão dividida por mais LP
   rende menos por token. Mais usuários não aumenta o yield — dilui.
2. **A receita do protocolo não escala com usuários.** Ela é 5% de (emissão fixa × preço).
   Com 100 usuários ou com 10.000, é a mesma cifra.
3. **O teto de TVL é o par inteiro.** R$ 1.419. Ninguém deposita mais do que a
   liquidez existente do par.

## 3. Os cenários

O vault domina o staking (o par está dormente), então recebe a emissão do pool 25
praticamente inteira, independente do tamanho da posição.

| | **100 usuários** | **10.000 usuários** | **10.000 usuários, par 100x mais fundo** |
| --- | --- | --- | --- |
| TVL total | R$ 1.419 | R$ 1.419 | R$ 141.938 |
| TVL por usuário | R$ 14,19 | R$ 0,14 | R$ 14,19 |
| APY bruto | 1,206% | 1,206% | 0,012% |
| APY líquido (5,5% de taxas) | 1,140% | 1,140% | 0,011% |
| Rendimento por usuário/ano | **R$ 0,16** | **R$ 0,0016** | R$ 0,0016 |
| **Receita do protocolo/ano** | **R$ 0,86** | **R$ 0,86** | **R$ 0,86** |
| Incentivo do keeper/ano | R$ 0,086 | R$ 0,086 | R$ 0,086 |
| Gas do harvest/ano | R$ 22,59 | R$ 22,59 | R$ 22,59 |
| **Resultado do keeper** | **perde R$ 22,50/ano** | **perde R$ 22,50/ano** | **perde R$ 22,50/ano** |

### 3.1 O que "10.000 pessoas usando diariamente" quer dizer

- A receita do protocolo **não muda**: R$ 0,86/ano. É uma fatia fixa de uma emissão fixa.
- Cada usuário passa a render **R$ 0,0016 por ano** — e pagar o gas de um depósito
  (R$ 0,0349) leva 22 dias para ser recuperado.
- O gas do `harvest` diário (R$ 0,0619) é **264x** o incentivo do keeper (R$ 0,000234/dia).
  Nenhum keeper racional chamaria `harvest()` diariamente.

### 3.2 O teto absoluto

A emissão **inteira** de todos os 30 pools do MasterChef vale R$ 0,40/dia =
**R$ 146/ano**. Todo o staking de GAMB no MasterChef, somado, rende isso. O protocolo
v2 é uma fatia disso, não um competidor.

## 4. Quando o protocolo fica viável

| Alvo | O que precisa acontecer |
| --- | --- |
| `harvest` cobrir o próprio gas | Valor por harvest ≥ R$ 12,38 (17,8 milhões de GAMB) = **264 dias** de emissão acumulada — ou o preço do GAMB subir **264x** (de 2,31e-10 para 6,11e-8 WBNB) |
| Protocolo capturando R$ 1.000/ano | Preço do GAMB **1.168x** o atual |
| Protocolo capturando R$ 1.000.000/ano | Preço do GAMB **1.168.234x** o atual |
| `poke` do oráculo coberto pelo lending pool | Os 48 pokes/dia custam **R$ 197/ano** e habilitam **R$ 16/ano** de juros → falta ~11x de subsídio |

**Existe um modo operável hoje**, mas é unattractive: harvest a cada ~264 dias (o gas
se amortiza, o keeper fica no zero e a taxa efetiva vira 0,02%/ano), com o lending pool
dormente até alguém subsidiar o keeper do oráculo. Nesse modo a v2 é um warehouse de
GAMB com 1,2% ao ano — não um negócio.

## 5. A ressalva que importa mais que tudo

O preço de 2,3143e-10 WBNB/GAMB vem de um par **dormente**: nenhuma troca desde
{blockTimestampLast}, que já esteve 54h atrás da ponta da chain. As reservas são um
snapshot de quando alguém negociou pela última vez. **Todo o modelo econômico acima
repousa sobre um preço de um par que não negocia.** Se o GAMB reprecificar, toda a
tabela muda — e é por isso que ela é um retrato, não uma previsão.

A conclusão honesta: **a v2, no estado on-chain atual, é uma demonstração técnica
correta, não um produto.** A arquitetura está pronta; falta o ativo ter preço e o par ter
liquidez. Nenhuma engenharia de contrato conserta isso — é mercado.

## 6. Reproduzindo

```bash
RPC="https://bsc-mainnet.public.blastapi.io"   # archive: os dataseed são podados
MC="0x77c1618248358f92Cb144269790103e67378A550"
LP="0x62dce0c4e2df11a1bcb2a718f9f43389d91310d5"

# tempo de bloco
B=$(cast block-number --rpc-url $RPC)
cast block $B --rpc-url $RPC --field timestamp
cast block $((B-2000)) --rpc-url $RPC --field timestamp

# emissão e share
cast call $MC "gambPerBlock()(uint256)" --rpc-url $RPC
cast call $MC "totalAllocPoint()(uint256)" --rpc-url $RPC
cast call $MC "poolInfo(uint256)(address,uint256,uint256,uint256)" 25 --rpc-url $RPC

# reservas e preço
cast call $LP "getReserves()(uint112,uint112,uint32)" --rpc-url $RPC
cast call $LP "totalSupply()(uint256)" --rpc-url $RPC

# gas real: rode o fork test com trace
cd contracts
BSC_RPC_URL=$RPC forge test --match-test test_fork_harvestCompoundsRealRewards -vvvv
BSC_RPC_URL=$RPC forge test --match-test test_fork_oracleStartsStaleBecauseThePairIsDormant -vvvv
```

Preço de referência do BNB usado aqui: US$ 3.000. O gas price medido (0,05 gwei) é o
mínimo da BSC; em congestionamento o BSC já chegou a 1 gwei (20x), o que piora todos
os números de keeper pela mesma ordem de grandeza.
