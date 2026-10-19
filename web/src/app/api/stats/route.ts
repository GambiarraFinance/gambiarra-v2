import { NextResponse } from "next/server";
import { CHAIN, CONTRACTS, SITE_URL, getLegacyStats, sourceLabel } from "@/lib/protocol";

export async function GET() {
  const legacy = await getLegacyStats();

  return NextResponse.json(
    {
      ok: true,
      generatedAt: new Date().toISOString(),
      site: SITE_URL,
      chain: { id: legacy.chainId, name: CHAIN.name },
      source: legacy.source,
      sourceLabel: sourceLabel(legacy.source),
      fork: legacy.source === "fork",
      blockNumber: legacy.blockNumber,
      masterChef: legacy.masterChef,
      gamb: legacy.gamb,
      lp: legacy.lp,
      v2: {
        phase: "pre-deploy",
        audited: false,
        holdsRealFunds: false,
        contracts: CONTRACTS.map(({ name, slug, status, address }) => ({ name, slug, status, address })),
      },
    },
    {
      headers: {
        "cache-control": "public, s-maxage=60, stale-while-revalidate=300",
      },
    },
  );
}
