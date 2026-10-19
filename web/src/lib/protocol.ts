import { createPublicClient, http, parseAbi } from "viem";
import { bsc } from "viem/chains";
import { formatCompactToken, formatTokenAmount } from "@/lib/format";

export const SITE_URL = process.env.NEXT_PUBLIC_SITE_URL ?? "https://gambiarra.finance";
export const GITHUB_URL = "https://github.com/GambiarraFinance";
export const REPO_URL = `${GITHUB_URL}/gambiarra-v2`;

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
 * Used as a fallback when every RPC is unreachable so the page and the
 * agent endpoints never lie with zeros.
 */
export const LEGACY_FALLBACK = {
  poolLength: 30,
  totalAllocPoint: "2557828962486000000000400000000",
  gambPerBlock: "3000000000000000000",
  owner: "0x0000000000000000000000000000000000000000",
  totalSupply: "2190000000000000000000000000",
  masterChefBalance: "329000000000000000000000000",
  decimals: 18,
} as const;

export type DataSource = "fork" | "rpc" | "fallback";

export type LegacyStats = {
  chainId: number;
  chainName: string;
  /** Where the numbers came from: local anvil fork, public RPC, or the audit snapshot. */
  source: DataSource;
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

const legacyAbi = parseAbi([
  "function poolLength() view returns (uint256)",
  "function totalAllocPoint() view returns (uint256)",
  "function gambPerBlock() view returns (uint256)",
  "function owner() view returns (address)",
  "function decimals() view returns (uint8)",
  "function totalSupply() view returns (uint256)",
  "function balanceOf(address account) view returns (uint256)",
]);

/**
 * Dev fork mode.
 *
 * In `next dev` the app talks to a local Anvil fork of BSC first
 * (`anvil --fork-url ... --chain-id 56`) and only falls back to public RPCs
 * when the fork is not running. Set `USE_BSC_FORK=0` to disable it, or point
 * `BSC_FORK_RPC_URL` at another fork endpoint (e.g. a remote Tenderly fork).
 *
 * Production builds never try the fork.
 */
export const FORK_URL = process.env.BSC_FORK_RPC_URL ?? "http://127.0.0.1:8545";
export const FORK_ENABLED = process.env.NODE_ENV !== "production" && process.env.USE_BSC_FORK !== "0";

type RpcCandidate = {
  source: Exclude<DataSource, "fallback">;
  url: string;
};

const PUBLIC_RPC_URLS = [
  process.env.BSC_RPC_URL,
  "https://bsc-dataseed.binance.org",
  "https://bsc-dataseed1.defibit.io",
  "https://bsc-dataseed1.ninicoin.io",
].filter(Boolean) as string[];

function rpcCandidates(): RpcCandidate[] {
  const candidates: RpcCandidate[] = [];
  if (FORK_ENABLED) candidates.push({ source: "fork", url: FORK_URL });
  for (const url of PUBLIC_RPC_URLS) candidates.push({ source: "rpc", url });
  return candidates;
}

function publicClientFor(url: string) {
  return createPublicClient({
    chain: bsc,
    transport: http(url, {
      timeout: 3_500,
      retryCount: 0,
      fetchOptions: { cache: "no-store" },
    }),
  });
}

function formatAmount(value: bigint, decimals: number): string {
  return formatTokenAmount(value, decimals, 4);
}

function formatCompact(value: bigint, decimals: number): string {
  return formatCompactToken(value, decimals, 2);
}

export function sourceLabel(source: DataSource): string {
  if (source === "fork") return "fork local (anvil)";
  if (source === "rpc") return "RPC público BSC";
  return "snapshot auditado";
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
      gambPerBlockFormatted: formatAmount(BigInt(LEGACY_FALLBACK.gambPerBlock), LEGACY_FALLBACK.decimals),
    },
    gamb: {
      address: ADDRESSES.gambToken,
      decimals: LEGACY_FALLBACK.decimals,
      totalSupply: LEGACY_FALLBACK.totalSupply,
      totalSupplyFormatted: formatCompact(BigInt(LEGACY_FALLBACK.totalSupply), LEGACY_FALLBACK.decimals),
      masterChefBalance: LEGACY_FALLBACK.masterChefBalance,
      masterChefBalanceFormatted: formatCompact(
        BigInt(LEGACY_FALLBACK.masterChefBalance),
        LEGACY_FALLBACK.decimals,
      ),
    },
    lp: {
      address: ADDRESSES.gambWbnbLp,
      poolIds: [16, 25],
      note: "O mesmo par GAMB/WBNB aparece nos pools 16 e 25 do MasterChef, com pesos diferentes.",
    },
  };
}

async function readLegacy(candidate: RpcCandidate): Promise<LegacyStats> {
  const client = publicClientFor(candidate.url);
  const masterChef = { address: ADDRESSES.masterChef, abi: legacyAbi } as const;
  const gamb = { address: ADDRESSES.gambToken, abi: legacyAbi } as const;

  const [chainId, blockNumber, poolLength, totalAllocPoint, gambPerBlock, owner, decimals] = await Promise.all([
    client.getChainId(),
    client.getBlockNumber(),
    client.readContract({ ...masterChef, functionName: "poolLength" }),
    client.readContract({ ...masterChef, functionName: "totalAllocPoint" }),
    client.readContract({ ...masterChef, functionName: "gambPerBlock" }),
    client.readContract({ ...masterChef, functionName: "owner" }),
    client.readContract({ ...gamb, functionName: "decimals" }),
  ]);

  const [totalSupply, masterChefBalance] = await Promise.all([
    client.readContract({ ...gamb, functionName: "totalSupply" }),
    client.readContract({ ...gamb, functionName: "balanceOf", args: [ADDRESSES.masterChef] }),
  ]);

  const ownerAddress = owner.toLowerCase();

  return {
    chainId,
    chainName: CHAIN.name,
    source: candidate.source,
    fetchedAt: new Date().toISOString(),
    blockNumber: blockNumber.toString(),
    masterChef: {
      address: ADDRESSES.masterChef,
      owner: ownerAddress,
      ownerRenounced: /^0x0{40}$/.test(ownerAddress),
      poolLength: Number(poolLength),
      totalAllocPoint: totalAllocPoint.toString(),
      gambPerBlock: gambPerBlock.toString(),
      gambPerBlockFormatted: formatAmount(gambPerBlock, decimals),
    },
    gamb: {
      address: ADDRESSES.gambToken,
      decimals,
      totalSupply: totalSupply.toString(),
      totalSupplyFormatted: formatCompact(totalSupply, decimals),
      masterChefBalance: masterChefBalance.toString(),
      masterChefBalanceFormatted: formatCompact(masterChefBalance, decimals),
    },
    lp: {
      address: ADDRESSES.gambWbnbLp,
      poolIds: [16, 25],
      note: "O mesmo par GAMB/WBNB aparece nos pools 16 e 25 do MasterChef, com pesos diferentes.",
    },
  };
}

/**
 * Reads the legacy MasterChef with viem (no indexer, no API key).
 *
 * Candidate order: dev fork (when enabled) → configured/public BSC RPCs.
 * Any failure moves to the next candidate and, if all fail, degrades to the
 * audited snapshot instead of a broken page.
 */
export async function getLegacyStats(): Promise<LegacyStats> {
  for (const candidate of rpcCandidates()) {
    try {
      return await readLegacy(candidate);
    } catch {
      // try the next candidate
    }
  }

  return fallbackStats();
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
