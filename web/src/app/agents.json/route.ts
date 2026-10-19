import { NextResponse } from "next/server";
import { ADDRESSES, CHAIN, CONTRACTS, GITHUB_URL, SITE_URL, getLegacyStats } from "@/lib/protocol";

export async function GET() {
  const legacy = await getLegacyStats();

  const manifest = {
    schemaVersion: "1.0",
    name: "Gambiarra Finance",
    description:
      "Vault auto-composto e camada de agentes sobre o MasterChef legado da Gambiarra Finance na BNB Smart Chain.",
    site: SITE_URL,
    source: GITHUB_URL,
    updatedAt: legacy.fetchedAt,
    chain: {
      id: CHAIN.id,
      name: CHAIN.name,
      explorer: CHAIN.explorer,
      nativeCurrency: CHAIN.currency,
    },
    status: {
      phase: "pre-deploy",
      audited: false,
      holdsRealFunds: false,
      tests: { framework: "foundry", passing: 13, failing: 0 },
      warning:
        "Os contratos v2 não foram deployados nem auditados por terceiros. Não envie fundos.",
    },
    contracts: {
      legacy: {
        mutable: false,
        masterChef: {
          address: ADDRESSES.masterChef,
          owner: legacy.masterChef.owner,
          ownerRenounced: legacy.masterChef.ownerRenounced,
          poolLength: legacy.masterChef.poolLength,
          gambPerBlock: legacy.masterChef.gambPerBlock,
          totalAllocPoint: legacy.masterChef.totalAllocPoint,
        },
        gambToken: {
          address: ADDRESSES.gambToken,
          decimals: legacy.gamb.decimals,
          totalSupply: legacy.gamb.totalSupply,
          masterChefBalance: legacy.gamb.masterChefBalance,
        },
        gambWbnbLp: {
          address: ADDRESSES.gambWbnbLp,
          poolIds: legacy.lp.poolIds,
          note: legacy.lp.note,
        },
      },
      v2: CONTRACTS.map((contract) => ({
        name: contract.name,
        slug: contract.slug,
        kind: contract.kind,
        description: contract.description,
        status: contract.status,
        address: contract.address,
      })),
    },
    endpoints: [
      {
        path: "/llms.txt",
        method: "GET",
        type: "text/plain",
        description: "Contexto em texto puro para LLMs.",
      },
      {
        path: "/agents.json",
        method: "GET",
        type: "application/json",
        description: "Este manifesto.",
      },
      {
        path: "/api/stats",
        method: "GET",
        type: "application/json",
        description: "Estado on-chain do MasterChef legado.",
      },
      {
        path: "/dashboard",
        method: "GET",
        type: "text/html",
        description: "Visão humana dos mesmos dados.",
      },
    ],
    capabilities: {
      read: ["legacy masterchef state", "legacy token state", "protocol manifest"],
      write: [],
      signsTransactions: false,
      requiresApiKey: false,
      payment: {
        protocol: "x402",
        status: "planned",
        note: "Nenhum facilitator, stablecoin ou endereço de pagamento foi definido.",
      },
    },
    safety: {
      untrustedAddresses: true,
      verifyAgainstManifest: true,
      serverHoldsPrivateKeys: false,
      maxLtvBps: 4000,
      liquidationThresholdBps: 5000,
      withdrawalsPausable: false,
      depositsPausable: true,
      upgradeable: false,
    },
    dataSource: legacy.source,
    blockNumber: legacy.blockNumber,
  };

  return NextResponse.json(manifest, {
    headers: {
      "cache-control": "public, s-maxage=60, stale-while-revalidate=300",
      "content-type": "application/json; charset=utf-8",
    },
  });
}
