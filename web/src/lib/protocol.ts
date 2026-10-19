export const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://gambiarra.finance";
export const GITHUB_URL = "https://github.com/GambiarraFinance";

export const CHAIN = {
  id: 56,
  name: "BNB Smart Chain",
  shortName: "BSC",
  explorer: "https://bscscan.com",
  currency: "BNB",
} as const;

export const ADDRESSES = {
  masterChef: "0x77c1618248358f92Cb144269790103e67378A550",
  gambToken: "0x18cde546d6ca4db3b6e62109adde38ee7b1dd068",
  gambWbnbLp: "0x62dce0c4e2df11a1bcb2a718f9f43389d91310d5",
} as const;

/**
 * Legacy MasterChef facts measured during the on-chain audit.
 * Used as a fallback when the public RPC is unreachable so the page and the
 * agent endpoints never lie with zeros.
 */
export const LEGACY_FALLBACK = {
  poolLength: 30,
  totalAllocPoint: "2560000000000000000000000000000",
  gambPerBlock: "3000000000000000000",
  owner: "0x0000000000000000000000000000000000000000",
  totalSupply: "2190000000000000000000000000",
  masterChefBalance: "329000000000000000000000000",
  decimals: 18,
} as const;

export type LegacyStats = {
  chainId: number;
  chainName: string;
  source: "rpc" | "fallback";
  fetchedAt: string;
  blockNumber: string | null;
  masterChef: {
    address: string;
    owner: string;
    ownerRenounced: boolean;
    poolLength: number;
    totalAllocPoint: string;
    gambPerBlock: string;
    gambPerBlockFormatted: string;
  };
  gamb: {
    address: string;
    decimals: number;
    totalSupply: string;
    totalSupplyFormatted: string;
    masterChefBalance: string;
    masterChefBalanceFormatted: string;
  };
  lp: {
    address: string;
    poolIds: number[];
    note: string;
  };
};

type RpcResponse = {
  result?: string;
  error?: { message?: string };
};

const RPC_ENDPOINTS = [
  process.env.BSC_RPC_URL,
  "https://bsc-dataseed.binance.org",
  "https://bsc-dataseed1.defibit.io",
  "https://bsc-dataseed1.ninicoin.io",
].filter(Boolean) as string[];

const SELECTORS = {
  poolLength: "0x081e3eda",
  totalAllocPoint: "0x17caf6f1",
  gambPerBlock: "0x7c5a1a5b",
  owner: "0x8da5cb5b",
  totalSupply: "0x18160ddd",
  balanceOf: "0x70a08231",
  decimals: "0x313ce567",
} as const;

function padAddress(address: string): string {
  return address.toLowerCase().replace(/^0x/, "").padStart(64, "0");
}

async function rpcCall(endpoint: string, to: string, data: string): Promise<string> {
  const response = await fetch(endpoint, {
    method: "POST",
    headers: { "content-type": "application/json" },
    body: JSON.stringify({
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [{ to, data }, "latest"],
    }),
    signal: AbortSignal.timeout(3_500),
    cache: "no-store",
  });

  if (!response.ok) throw new Error(`RPC ${response.status}`);
  const payload = (await response.json()) as RpcResponse;
  if (payload.error || typeof payload.result !== "string") {
    throw new Error(payload.error?.message ?? "empty RPC result");
  }
  return payload.result;
}

async function rpcBlockNumber(endpoint: string): Promise<string | null> {
  try {
    const response = await fetch(endpoint, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify({ jsonrpc: "2.0", id: 1, method: "eth_blockNumber", params: [] }),
      signal: AbortSignal.timeout(3_500),
      cache: "no-store",
    });
    const payload = (await response.json()) as RpcResponse;
    return typeof payload.result === "string" ? BigInt(payload.result).toString() : null;
  } catch {
    return null;
  }
}

function formatUnits(value: bigint, decimals: number): string {
  const base = BigInt(10) ** BigInt(decimals);
  const whole = value / base;
  const fraction = (value % base).toString().padStart(decimals, "0").replace(/0+$/, "");
  return fraction.length > 0 ? `${whole}.${fraction.slice(0, 4)}` : whole.toString();
}

function formatCompact(value: bigint, decimals: number): string {
  const asNumber = Number(value) / 10 ** decimals;
  if (!Number.isFinite(asNumber)) return value.toString();
  if (asNumber >= 1e9) return `${(asNumber / 1e9).toFixed(2)}B`;
  if (asNumber >= 1e6) return `${(asNumber / 1e6).toFixed(1)}M`;
  if (asNumber >= 1e3) return `${(asNumber / 1e3).toFixed(1)}K`;
  return asNumber.toFixed(2).replace(/\.00$/, "");
}

function fallbackStats(): LegacyStats {
  return {
    chainId: CHAIN.id,
    chainName: CHAIN.name,
    source: "fallback",
    fetchedAt: new Date().toISOString(),
    blockNumber: null,
    masterChef: {
      address: ADDRESSES.masterChef,
      owner: LEGACY_FALLBACK.owner,
      ownerRenounced: true,
      poolLength: LEGACY_FALLBACK.poolLength,
      totalAllocPoint: LEGACY_FALLBACK.totalAllocPoint,
      gambPerBlock: LEGACY_FALLBACK.gambPerBlock,
      gambPerBlockFormatted: "3",
    },
    gamb: {
      address: ADDRESSES.gambToken,
      decimals: LEGACY_FALLBACK.decimals,
      totalSupply: LEGACY_FALLBACK.totalSupply,
      totalSupplyFormatted: "2.19B",
      masterChefBalance: LEGACY_FALLBACK.masterChefBalance,
      masterChefBalanceFormatted: "329M",
    },
    lp: {
      address: ADDRESSES.gambWbnbLp,
      poolIds: [16, 25],
      note: "O mesmo par GAMB/WBNB aparece nos pools 16 e 25 do MasterChef, com pesos diferentes.",
    },
  };
}

/**
 * Reads the legacy MasterChef directly over JSON-RPC (no indexer, no API key).
 * Public BSC RPCs are flaky, so any failure degrades to audited snapshot values
 * instead of a broken page.
 */
export async function getLegacyStats(): Promise<LegacyStats> {
  const base = fallbackStats();

  for (const endpoint of RPC_ENDPOINTS) {
    try {
      const [poolLengthHex, totalAllocHex, perBlockHex, ownerHex, supplyHex, balanceHex, decimalsHex, blockNumber] =
        await Promise.all([
          rpcCall(endpoint, ADDRESSES.masterChef, SELECTORS.poolLength),
          rpcCall(endpoint, ADDRESSES.masterChef, SELECTORS.totalAllocPoint),
          rpcCall(endpoint, ADDRESSES.masterChef, SELECTORS.gambPerBlock),
          rpcCall(endpoint, ADDRESSES.masterChef, SELECTORS.owner),
          rpcCall(endpoint, ADDRESSES.gambToken, SELECTORS.totalSupply),
          rpcCall(endpoint, ADDRESSES.gambToken, `${SELECTORS.balanceOf}${padAddress(ADDRESSES.masterChef)}`),
          rpcCall(endpoint, ADDRESSES.gambToken, SELECTORS.decimals),
          rpcBlockNumber(endpoint),
        ]);

      const decimals = Number(BigInt(decimalsHex));
      const totalSupply = BigInt(supplyHex);
      const masterChefBalance = BigInt(balanceHex);
      const perBlock = BigInt(perBlockHex);
      const owner = `0x${ownerHex.slice(-40)}`.toLowerCase();

      return {
        chainId: CHAIN.id,
        chainName: CHAIN.name,
        source: "rpc",
        fetchedAt: new Date().toISOString(),
        blockNumber,
        masterChef: {
          address: ADDRESSES.masterChef,
          owner,
          ownerRenounced: /^0x0{40}$/.test(owner),
          poolLength: Number(BigInt(poolLengthHex)),
          totalAllocPoint: BigInt(totalAllocHex).toString(),
          gambPerBlock: perBlock.toString(),
          gambPerBlockFormatted: formatUnits(perBlock, decimals),
        },
        gamb: {
          address: ADDRESSES.gambToken,
          decimals,
          totalSupply: totalSupply.toString(),
          totalSupplyFormatted: formatCompact(totalSupply, decimals),
          masterChefBalance: masterChefBalance.toString(),
          masterChefBalanceFormatted: formatCompact(masterChefBalance, decimals),
        },
        lp: base.lp,
      };
    } catch {
      // try the next endpoint
    }
  }

  return base;
}

export const CONTRACTS = [
  {
    name: "GambVault",
    slug: "vault",
    kind: "ERC4626 auto-compounder",
    description:
      "Recebe LP GAMB/WBNB, faz stake no pool 25 do MasterChef legado e recompõe os rewards via keeper — sem custódia, sem pausa de saque.",
    status: "spec",
    address: null,
  },
  {
    name: "GambTwapOracle",
    slug: "oracle",
    kind: "TWAP + fair LP value",
    description:
      "Preço de GAMB em WBNB com janela mínima de 30 min e fórmula geométrica de fair value para resistir a skew de reservas num único bloco.",
    status: "spec",
    address: null,
  },
  {
    name: "GambLendingPool",
    slug: "lending",
    kind: "Single-asset lending",
    description:
      "Pool isolado de WBNB com colateral em shares do vault, LTV conservador, liquidação permissionless e juros estilo Compound.",
    status: "spec",
    address: null,
  },
  {
    name: "GambLeverageZap",
    slug: "zap",
    kind: "Flash-swap leverage",
    description:
      "Abre e fecha posição alavancada em uma transação via flash swap da Pancake V2. A dívida persistente fica no lending pool, nunca no zap.",
    status: "spec",
    address: null,
  },
] as const;

export const AGENT_ENDPOINTS = [
  {
    path: "/llms.txt",
    method: "GET",
    description: "Contexto em texto puro para LLMs: o que é, onde está e o que não fazer.",
  },
  {
    path: "/agents.json",
    method: "GET",
    description: "Manifesto legível por máquina com contratos, endpoints e limites de segurança.",
  },
  {
    path: "/api/stats",
    method: "GET",
    description: "Estado on-chain do MasterChef legado em JSON, com fallback auditado.",
  },
] as const;
