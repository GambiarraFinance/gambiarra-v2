import type { Metadata } from "next";
import Link from "next/link";
import { connection } from "next/server";
import { ADDRESSES, CHAIN, CONTRACTS, getLegacyStats, sourceLabel } from "@/lib/protocol";
import { formatScientific } from "@/lib/format";
import { WalletPanel } from "@/components/WalletPanel";

export const metadata: Metadata = {
  title: "Dashboard",
  description:
    "Estado on-chain do MasterChef legado da Gambiarra Finance na BSC: pools, emissão, owner e saldo de GAMB — lido direto por RPC.",
  alternates: { canonical: "/dashboard" },
};

export const instant = false;

function shortAddress(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

export default async function DashboardPage() {
  await connection();
  const legacy = await getLegacyStats();

  const cards = [
    {
      label: "Pools no MasterChef",
      value: String(legacy.masterChef.poolLength),
      note: "inclui o par GAMB/WBNB duplicado nos ids 16 e 25",
      accent: "bg-sun",
    },
    {
      label: "Emissão por bloco",
      value: `${legacy.masterChef.gambPerBlockFormatted} GAMB`,
      note: "constante imutável desde o deploy",
      accent: "bg-tropic text-sand",
    },
    {
      label: "GAMB no contrato",
      value: legacy.gamb.masterChefBalanceFormatted,
      note: `supply total de ${legacy.gamb.totalSupplyFormatted} GAMB`,
      accent: "bg-ocean text-sand",
    },
    {
      label: "Owner",
      value: legacy.masterChef.ownerRenounced ? "renunciado" : shortAddress(legacy.masterChef.owner),
      note: legacy.masterChef.ownerRenounced
        ? "0x000…000 — nenhuma função de admin é chamável"
        : "owner ainda ativo",
      accent: "bg-coral text-sand",
    },
  ];

  return (
    <div className="flex min-h-screen flex-col">
      <header className="border-b border-ink/12 bg-sand/85 backdrop-blur-md">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-4 px-5 py-4 sm:px-8">
          <Link href="/" className="display text-xl" aria-label="Voltar para a home">
            gambiarra<span className="text-tropic">.</span>
          </Link>
          <div className="flex items-center gap-3">
            <span className="chip text-ink-soft">
              <span
                className={`inline-block h-2 w-2 rounded-full ${
                  legacy.source === "fork"
                    ? "bg-ocean"
                    : legacy.source === "rpc"
                      ? "bg-tropic"
                      : "bg-sun"
                }`}
              />
              {legacy.source === "fork" ? "fork local" : legacy.source === "rpc" ? "rpc ao vivo" : "snapshot"}
            </span>
            <Link href="/" className="btn btn-ghost px-4 py-2 text-xs">
              ← Home
            </Link>
          </div>
        </div>
      </header>

      <main id="conteudo" className="mx-auto w-full max-w-7xl flex-1 px-5 py-12 sm:px-8 lg:py-16">
        <div className="flex flex-wrap items-end justify-between gap-6">
          <div>
            <p className="eyebrow text-tropic">dashboard · {CHAIN.shortName}</p>
            <h1 className="display mt-3 text-[clamp(2.6rem,5.6vw,4.8rem)]">
              Estado da <span className="text-tropic">gambiarra</span>.
            </h1>
            <p className="copy mt-4 max-w-2xl">
              Números lidos direto do contrato legado com <strong className="text-ink">viem</strong>: fork
              local quando você roda em dev, RPC público em produção. Se a leitura falhar, a página mostra o
              snapshot auditado — nunca zero.
            </p>
          </div>
          <div className="rounded-2xl border border-ink/15 bg-white/45 px-5 py-4">
            <p className="eyebrow text-ink-soft">camada v2</p>
            <p className="display mt-1 text-2xl text-coral">pré-deploy</p>
            <p className="mt-1 font-mono text-[10px] uppercase tracking-widest text-ink-soft">
              sem fundos reais
            </p>
          </div>
        </div>

        <section aria-label="Métricas do MasterChef legado" className="mt-10 grid grid-cols-1 gap-4 sm:grid-cols-2 xl:grid-cols-4">
          {cards.map((card) => (
            <article key={card.label} className={`card tilt-hover p-5 ${card.accent}`}>
              <p className="eyebrow opacity-70">{card.label}</p>
              <p className="display mt-3 break-words text-3xl">{card.value}</p>
              <p className="mt-3 text-xs leading-relaxed opacity-80">{card.note}</p>
            </article>
          ))}
        </section>

        <div className="mt-10">
          <WalletPanel />
        </div>

        <div className="mt-10 grid grid-cols-1 gap-6 lg:grid-cols-[1.15fr_0.85fr]">
          <section className="card p-6 sm:p-8" aria-labelledby="legado-title">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h2 id="legado-title" className="display text-2xl">
                MasterChef legado
              </h2>
              <span className="chip text-ink-soft">imutável</span>
            </div>

            <dl className="mt-6 divide-y divide-ink/10">
              {[
                ["Endereço", shortAddress(ADDRESSES.masterChef)],
                ["Token GAMB", shortAddress(ADDRESSES.gambToken)],
                ["LP GAMB/WBNB", shortAddress(ADDRESSES.gambWbnbLp)],
                ["totalAllocPoint", formatScientific(BigInt(legacy.masterChef.totalAllocPoint), 3)],
                ["Bloco lido", legacy.blockNumber ?? "não disponível"],
                ["Fonte", sourceLabel(legacy.source)],
              ].map(([label, value]) => (
                <div key={label} className="flex flex-wrap items-center justify-between gap-3 py-3">
                  <dt className="font-mono text-[11px] uppercase tracking-widest text-ink-soft">{label}</dt>
                  <dd className="font-mono text-sm">{value}</dd>
                </div>
              ))}
            </dl>

            <div className="mt-6 rounded-xl border border-coral/30 bg-coral/8 p-4">
              <p className="font-semibold text-coral">O detalhe que importa</p>
              <p className="copy mt-1 text-sm">
                Seis pools concentram praticamente toda a emissão, e o mesmo par GAMB/WBNB aparece nos
                pools <strong className="text-ink">16</strong> e <strong className="text-ink">25</strong> com
                pesos diferentes. Qualquer integração que assuma um pool por LP token está errada.
              </p>
            </div>

            <div className="mt-6 flex flex-wrap gap-3">
              <a
                href={`${CHAIN.explorer}/address/${ADDRESSES.masterChef}`}
                target="_blank"
                rel="noreferrer"
                className="btn btn-primary px-4 py-2.5 text-xs"
              >
                Ver no BscScan ↗
              </a>
              <a href="/api/stats" className="btn btn-ghost px-4 py-2.5 text-xs">
                JSON bruto
              </a>
            </div>
          </section>

          <section className="card-dark p-6 sm:p-8" aria-labelledby="v2-title">
            <div className="flex flex-wrap items-center justify-between gap-3">
              <h2 id="v2-title" className="display text-2xl">
                Camada v2
              </h2>
              <span className="chip text-sun">pré-deploy</span>
            </div>
            <p className="mt-4 text-sm leading-relaxed text-sand/70">
              Os quatro contratos novos compilam e têm testes. Ainda não há endereço em mainnet —
              quando houver, ele aparece aqui automaticamente.
            </p>

            <ul className="mt-6 space-y-4">
              {CONTRACTS.map((contract, index) => (
                <li key={contract.slug} className="flex items-start gap-3 border-t border-sand/15 pt-4">
                  <span className="font-mono text-[11px] text-sun">0{index + 1}</span>
                  <div>
                    <p className="font-semibold">{contract.name}</p>
                    <p className="mt-0.5 text-xs leading-relaxed text-sand/60">{contract.kind}</p>
                  </div>
                  <span className="ml-auto font-mono text-[10px] uppercase tracking-widest text-sand/45">
                    spec
                  </span>
                </li>
              ))}
            </ul>

            <div className="mt-6 rounded-xl border border-sand/20 bg-sand/5 p-4">
              <p className="font-mono text-[11px] uppercase tracking-widest text-sun">testes</p>
              <p className="display mt-1 text-3xl">17 / 17</p>
              <p className="mt-1 text-xs text-sand/60">
                Foundry · + 16 fork tests contra a BSC real (gated por BSC_RPC_URL)
              </p>
            </div>
          </section>
        </div>

        <section className="mt-10" aria-labelledby="agent-title">
          <div className="card flex flex-col gap-4 p-6 sm:flex-row sm:items-center sm:justify-between sm:p-8">
            <div>
              <h2 id="agent-title" className="display text-2xl">
                Quer que um agente monitore isso?
              </h2>
              <p className="copy mt-2 max-w-xl text-sm">
                Use <code className="rounded bg-ink/6 px-1.5 py-0.5 font-mono text-xs">/agents.json</code> para
                descobrir contratos e limites, e <code className="rounded bg-ink/6 px-1.5 py-0.5 font-mono text-xs">/api/stats</code>{" "}
                para o estado atual. Nenhum endpoint assina transação.
              </p>
            </div>
            <div className="flex shrink-0 gap-2">
              <a href="/agents.json" className="btn btn-primary px-4 py-2.5 text-xs">
                agents.json
              </a>
              <a href="/llms.txt" className="btn btn-sun px-4 py-2.5 text-xs">
                llms.txt
              </a>
            </div>
          </div>
        </section>

        <p className="mt-8 font-mono text-[11px] uppercase tracking-widest text-ink-soft">
          lido em {new Date(legacy.fetchedAt).toLocaleString("pt-BR")} · revalida a cada 60s
        </p>
      </main>

      <footer className="border-t border-ink/15 py-6">
        <p className="mx-auto max-w-7xl px-5 text-xs text-ink-soft sm:px-8">
          Gambiarra Finance · código aberto · não é conselho financeiro.
        </p>
      </footer>
    </div>
  );
}
