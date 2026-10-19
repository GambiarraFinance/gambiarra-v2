import Link from "next/link";
import { connection } from "next/server";
import { HeroScene } from "@/components/HeroScene";
import {
  ADDRESSES,
  AGENT_ENDPOINTS,
  CHAIN,
  CONTRACTS,
  GITHUB_URL,
  SITE_URL,
  getLegacyStats,
} from "@/lib/protocol";

export const instant = false;

function FlipFlopMark({ className = "h-8 w-8" }: { className?: string }) {
  return (
    <svg viewBox="0 0 32 32" className={className} aria-hidden="true" fill="none">
      <path
        d="M16 3.5c4.2 0 6.1 2.4 6.6 6.4.3 2.4-.6 6.1-.3 9.2.4 4.8-1.9 9.4-6.3 9.4s-6.7-4.6-6.3-9.4c.3-3.1-.6-6.8-.3-9.2C9.9 5.9 11.8 3.5 16 3.5Z"
        fill="currentColor"
      />
      <path
        d="M10.6 12.4 16 16.6l5.4-4.2"
        stroke="var(--color-sand)"
        strokeWidth="1.9"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
      <circle cx="16" cy="16.6" r="1.5" fill="var(--color-sand)" />
    </svg>
  );
}

function shortAddress(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

function scientific(value: string) {
  const asNumber = Number(value);
  if (!Number.isFinite(asNumber) || asNumber === 0) return value;
  return asNumber.toExponential(1).replace("e+", "e");
}

export default async function Home() {
  await connection();
  const legacy = await getLegacyStats();

  const jsonLd = {
    "@context": "https://schema.org",
    "@type": "SoftwareApplication",
    name: "Gambiarra Finance",
    applicationCategory: "FinanceApplication",
    operatingSystem: "Web, API",
    url: SITE_URL,
    description:
      "Vault auto-composto e camada de agentes sobre o MasterChef legado da Gambiarra Finance na BNB Smart Chain.",
    offers: { "@type": "Offer", price: "0", priceCurrency: "USD" },
    author: { "@type": "Person", name: "codingsh", url: "https://github.com/codingsh" },
    codeRepository: GITHUB_URL,
  };

  return (
    <div className="flex min-h-screen flex-col">
      <script
        type="application/ld+json"
        dangerouslySetInnerHTML={{ __html: JSON.stringify(jsonLd) }}
      />

      {/* ---------------------------------------------------------------- */}
      {/* Header                                                            */}
      {/* ---------------------------------------------------------------- */}
      <header className="sticky top-0 z-40 border-b border-ink/12 bg-sand/85 backdrop-blur-md">
        <div className="mx-auto flex max-w-7xl items-center justify-between gap-4 px-5 py-4 sm:px-8">
          <Link href="/" className="flex items-center gap-2.5" aria-label="Gambiarra Finance, início">
            <span className="text-tropic">
              <FlipFlopMark />
            </span>
            <span className="display text-xl tracking-tight">
              gambiarra<span className="text-tropic">.</span>
            </span>
          </Link>

          <nav aria-label="Navegação principal" className="hidden items-center gap-7 text-sm font-medium md:flex">
            <a href="#legado" className="link-underline">
              O legado
            </a>
            <a href="#stack" className="link-underline">
              O stack
            </a>
            <a href="#agentes" className="link-underline">
              Agentes
            </a>
            <Link href="/dashboard" className="link-underline">
              Dashboard
            </Link>
          </nav>

          <div className="flex items-center gap-2">
            <a
              href={GITHUB_URL}
              target="_blank"
              rel="noreferrer"
              className="btn btn-ghost hidden px-4 py-2 text-xs sm:inline-flex"
            >
              GitHub ↗
            </a>
            <Link href="/dashboard" className="btn btn-primary px-4 py-2.5 text-xs sm:text-sm">
              Abrir dashboard
            </Link>
          </div>
        </div>
      </header>

      <main id="conteudo" className="flex-1">
        {/* -------------------------------------------------------------- */}
        {/* Hero                                                           */}
        {/* -------------------------------------------------------------- */}
        <section className="relative overflow-hidden">
          <div
            aria-hidden="true"
            className="pin-stripe absolute inset-x-0 top-0 h-1.5 opacity-90"
          />
          <div className="mx-auto grid grid-cols-1 max-w-7xl items-center gap-10 px-5 pb-16 pt-12 sm:px-8 lg:grid-cols-[1.08fr_0.92fr] lg:gap-6 lg:pb-24 lg:pt-16">
            <div>
              <p className="eyebrow fade-up flex flex-wrap items-center gap-3 text-ink-soft">
                <span className="inline-flex h-2 w-2 rounded-full bg-tropic" />
                {CHAIN.shortName} · open source · agent-first
              </p>

              <h1 className="display fade-up fade-up-1 mt-5 text-[clamp(3rem,7.4vw,6.4rem)]">
                DeFi de <span className="text-tropic">chinelo</span>.
                <br />
                Cérebro de <span className="relative inline-block">
                  <span className="relative z-10">agente</span>
                  <span
                    aria-hidden="true"
                    className="absolute inset-x-0 bottom-[0.08em] z-0 h-[0.32em] -rotate-1 bg-sun"
                  />
                </span>
                .
              </h1>

              <p className="copy fade-up fade-up-2 mt-6 max-w-xl text-lg">
                O MasterChef da Gambiarra foi abandonado com o dono renunciado em 2021 — e
                continua pagando <strong className="font-semibold text-ink">3 GAMB por bloco, para sempre</strong>.
                Construímos uma camada nova por cima: vault auto-composto, oráculo TWAP e uma API
                desenhada para agentes autônomos, não para cliques.
              </p>

              <div className="fade-up fade-up-3 mt-8 flex flex-wrap items-center gap-3">
                <Link href="/dashboard" className="btn btn-primary">
                  Ver o dashboard <span aria-hidden="true">→</span>
                </Link>
                <Link href="/agents.json" className="btn btn-sun">
                  agents.json
                </Link>
                <a href="#agentes" className="btn btn-ghost">
                  Como um agente entra
                </a>
              </div>

              <dl className="mt-12 grid max-w-xl grid-cols-2 gap-x-6 gap-y-5 border-t border-ink/15 pt-6 sm:grid-cols-4">
                <div>
                  <dt className="eyebrow text-ink-soft">Pools legados</dt>
                  <dd className="display mt-1 text-3xl">{legacy.masterChef.poolLength}</dd>
                </div>
                <div>
                  <dt className="eyebrow text-ink-soft">Emissão / bloco</dt>
                  <dd className="display mt-1 text-3xl">{legacy.masterChef.gambPerBlockFormatted} GAMB</dd>
                </div>
                <div>
                  <dt className="eyebrow text-ink-soft">Owner</dt>
                  <dd className="display mt-1 text-3xl">0x0</dd>
                </div>
                <div>
                  <dt className="eyebrow text-ink-soft">Testes</dt>
                  <dd className="display mt-1 text-3xl">13</dd>
                </div>
              </dl>
            </div>

            <div className="relative">
              <HeroScene />
              <div
                aria-hidden="true"
                className="float-soft absolute -left-2 top-6 hidden rotate-[-7deg] rounded-xl border border-ink/20 bg-white/70 px-3 py-2 font-mono text-[10px] uppercase tracking-widest text-ink-soft shadow-sm sm:block"
              >
                owner() = 0x000…000
              </div>
              <div
                aria-hidden="true"
                className="float-soft absolute -right-1 bottom-8 hidden rotate-[4deg] rounded-xl border border-ink/20 bg-tropic px-3 py-2 font-mono text-[10px] uppercase tracking-widest text-sand shadow-sm sm:block"
                style={{ animationDelay: "1.4s" }}
              >
                pool 25 · GAMB/WBNB
              </div>
            </div>
          </div>
        </section>

        {/* -------------------------------------------------------------- */}
        {/* Ticker                                                         */}
        {/* -------------------------------------------------------------- */}
        <div className="overflow-hidden border-y border-ink bg-ink py-3 text-sand">
          <div className="ticker-track" aria-hidden="true">
            {[0, 1].map((copy) => (
              <div key={copy} className="flex shrink-0 items-center">
                {[
                  "MasterChef sem dono desde 2021",
                  "3 GAMB por bloco, imutável",
                  "auto-compounder permissionless",
                  "TWAP de 30 minutos",
                  "liquidação permissionless",
                  "llms.txt para agentes",
                  "código aberto, sem custódia",
                ].map((item) => (
                  <span key={`${copy}-${item}`} className="flex items-center">
                    <span className="px-6 font-mono text-[11px] uppercase tracking-[0.18em]">{item}</span>
                    <span className="text-sun">✦</span>
                  </span>
                ))}
              </div>
            ))}
          </div>
        </div>

        {/* -------------------------------------------------------------- */}
        {/* Legacy                                                         */}
        {/* -------------------------------------------------------------- */}
        <section id="legado" className="mx-auto max-w-7xl scroll-mt-24 px-5 py-20 sm:px-8 lg:py-28">
          <div className="grid grid-cols-1 gap-12 lg:grid-cols-[0.9fr_1.1fr]">
            <div>
              <p className="eyebrow text-tropic">01 — o legado</p>
              <h2 className="display mt-4 text-[clamp(2.3rem,4.6vw,4rem)]">
                O contrato não morreu.
                <br />
                Só ficou <span className="text-coral">sozinho</span>.
              </h2>
              <p className="copy mt-6 max-w-lg">
                Em 2021, o <code className="rounded bg-ink/6 px-1.5 py-0.5 font-mono text-sm">renounceOwnership()</code>{" "}
                tirou o dono do MasterChef. Ninguém pode mudar pesos, emissão ou criar pools. Ao mesmo
                tempo, seis pools herdaram praticamente toda a emissão e ficaram com TVL perto de zero.
                Isso não é um bug de segurança: é uma <strong className="font-semibold text-ink">assimetria de
                distribuição</strong> que continua disponível para quem construir em cima.
              </p>
              <p className="copy mt-4 max-w-lg">
                A Gambiarra v2 não toca no contrato antigo. Ela o trata como infraestrutura pública:
                imutável, sem admin, e ainda assim útil.
              </p>

              <div className="mt-8 flex flex-wrap gap-2">
                <a
                  href={`${CHAIN.explorer}/address/${ADDRESSES.masterChef}`}
                  target="_blank"
                  rel="noreferrer"
                  className="chip text-ink-soft hover:text-ink"
                >
                  MasterChef {shortAddress(ADDRESSES.masterChef)} ↗
                </a>
                <a
                  href={`${CHAIN.explorer}/address/${ADDRESSES.gambWbnbLp}`}
                  target="_blank"
                  rel="noreferrer"
                  className="chip text-ink-soft hover:text-ink"
                >
                  LP GAMB/WBNB ↗
                </a>
              </div>
            </div>

            <div className="grid grid-cols-1 gap-4 sm:grid-cols-2">
              {[
                {
                  label: "Pools ativos",
                  value: String(legacy.masterChef.poolLength),
                  note: "O mesmo par GAMB/WBNB aparece nos pools 16 e 25.",
                  accent: "bg-sun",
                },
                {
                  label: "Emissão fixa",
                  value: `${legacy.masterChef.gambPerBlockFormatted} GAMB`,
                  note: "Por bloco. Sem função de update. Para sempre.",
                  accent: "bg-tropic text-sand",
                },
                {
                  label: "totalAllocPoint",
                  value: scientific(legacy.masterChef.totalAllocPoint),
                  note: "Seis pools legados concentram quase todo o peso.",
                  accent: "bg-ocean text-sand",
                },
                {
                  label: "GAMB no MasterChef",
                  value: legacy.gamb.masterChefBalanceFormatted,
                  note: `Supply total: ${legacy.gamb.totalSupplyFormatted} GAMB.`,
                  accent: "bg-coral text-sand",
                },
              ].map((stat) => (
                <article key={stat.label} className={`card tilt-hover p-5 ${stat.accent}`}>
                  <p className="eyebrow opacity-70">{stat.label}</p>
                  <p className="display mt-3 text-4xl">{stat.value}</p>
                  <p className="mt-3 text-sm leading-relaxed opacity-80">{stat.note}</p>
                </article>
              ))}
            </div>
          </div>

          <p className="mt-6 font-mono text-[11px] uppercase tracking-widest text-ink-soft">
            fonte: {legacy.source === "rpc" ? "RPC público BSC" : "snapshot auditado"} · lido em{" "}
            {new Date(legacy.fetchedAt).toLocaleDateString("pt-BR")}
          </p>
        </section>

        {/* -------------------------------------------------------------- */}
        {/* Stack                                                          */}
        {/* -------------------------------------------------------------- */}
        <section id="stack" className="scroll-mt-24 border-y border-ink/15 bg-sand-deep/60">
          <div className="mx-auto max-w-7xl px-5 py-20 sm:px-8 lg:py-28">
            <div className="flex flex-wrap items-end justify-between gap-6">
              <div>
                <p className="eyebrow text-tropic">02 — o stack</p>
                <h2 className="display mt-4 max-w-2xl text-[clamp(2.3rem,4.6vw,4rem)]">
                  Quatro contratos.
                  <br />
                  Zero babá.
                </h2>
              </div>
              <p className="copy max-w-md">
                Tudo é permissionless: qualquer keeper, bot ou agente pode chamar harvest, atualizar o
                oráculo ou liquidar uma posição. Não existe botão de admin escondido no fluxo de
                fundos.
              </p>
            </div>

            <div className="mt-12 grid grid-cols-1 gap-4 md:grid-cols-2">
              {CONTRACTS.map((contract, index) => (
                <article key={contract.slug} className="card tilt-hover group relative overflow-hidden p-6 sm:p-8">
                  <div className="flex flex-wrap items-start justify-between gap-x-4 gap-y-3">
                    <div className="min-w-0">
                      <p className="font-mono text-[11px] uppercase tracking-[0.18em] text-ink-soft">
                        0{index + 1} / {contract.kind}
                      </p>
                      <h3 className="display mt-3 text-3xl">{contract.name}</h3>
                    </div>
                    <span className="chip whitespace-nowrap text-ink-soft">
                      {contract.status === "spec" ? "pré-deploy" : contract.status}
                    </span>
                  </div>
                  <p className="copy mt-4 max-w-lg">{contract.description}</p>
                  <div className="mt-6 flex items-center gap-3 border-t border-ink/12 pt-4 font-mono text-[11px] uppercase tracking-widest text-ink-soft">
                    <span className="inline-block h-2 w-2 rounded-full bg-tropic" />
                    código aberto
                    <span aria-hidden="true">·</span>
                    <span>sem custódia</span>
                  </div>
                  <span
                    aria-hidden="true"
                    className="pointer-events-none absolute -right-8 -top-8 h-24 w-24 rounded-full bg-sun/0 transition-colors duration-300 group-hover:bg-sun/25"
                  />
                </article>
              ))}
            </div>

            <div className="mt-6 grid grid-cols-1 gap-4 md:grid-cols-3">
              {[
                ["Sem upgrade proxy", "Contratos imutáveis. O que foi deployado é o que fica."],
                ["Sem pausa de saque", "Depósitos podem pausar; saque nunca. O dinheiro é do usuário."],
                ["Limites no código", "Fee, LTV, bônus e slippage têm teto em constantes imutáveis."],
              ].map(([title, text]) => (
                <div key={title} className="rounded-2xl border border-ink/12 bg-sand/50 p-5">
                  <p className="font-semibold">{title}</p>
                  <p className="copy mt-2 text-sm">{text}</p>
                </div>
              ))}
            </div>
          </div>
        </section>

        {/* -------------------------------------------------------------- */}
        {/* Agents                                                         */}
        {/* -------------------------------------------------------------- */}
        <section id="agentes" className="scroll-mt-24 bg-ink text-sand">
          <div className="mx-auto max-w-7xl px-5 py-20 sm:px-8 lg:py-28">
            <div className="grid grid-cols-1 gap-12 lg:grid-cols-[1fr_1fr]">
              <div>
                <p className="eyebrow text-sun">03 — agentes primeiro</p>
                <h2 className="display mt-4 text-[clamp(2.3rem,4.6vw,4rem)]">
                  A interface primária
                  <br />
                  não é um <span className="text-sun">botão</span>.
                </h2>
                <p className="mt-6 max-w-lg leading-relaxed text-sand/75">
                  O site existe para humanos entenderem o que está acontecendo. A operação real
                  acontece por endpoints estáveis, texto puro e JSON sem surpresa. Um agente deve
                  conseguir descobrir contratos, limites e riscos sem parsear HTML.
                </p>

                <ul className="mt-8 space-y-5">
                  {AGENT_ENDPOINTS.map((endpoint) => (
                    <li key={endpoint.path} className="border-t border-sand/15 pt-4">
                      <div className="flex flex-wrap items-center gap-3">
                        <span className="chip text-sun">{endpoint.method}</span>
                        <Link href={endpoint.path} className="font-mono text-sm text-sand underline-offset-4 hover:underline">
                          {endpoint.path}
                        </Link>
                      </div>
                      <p className="mt-2 text-sm leading-relaxed text-sand/65">{endpoint.description}</p>
                    </li>
                  ))}
                </ul>

                <div className="mt-8 rounded-2xl border border-sun/30 bg-sun/10 p-5">
                  <p className="eyebrow text-sun">roadmap · x402</p>
                  <p className="mt-2 text-sm leading-relaxed text-sand/75">
                    Rotas premium (analytics profundo, execução de harvest como serviço) vão poder ser
                    pagas por request com x402 na BSC. O facilitator e a stablecoin ainda serão
                    confirmados antes de qualquer endereço entrar no código.
                  </p>
                </div>
              </div>

              <div className="card-dark overflow-hidden">
                <div className="flex items-center justify-between border-b border-sand/15 px-5 py-3">
                  <span className="font-mono text-[11px] uppercase tracking-[0.18em] text-sand/60">
                    agent loop
                  </span>
                  <span className="flex gap-1.5" aria-hidden="true">
                    <span className="h-2.5 w-2.5 rounded-full bg-coral/80" />
                    <span className="h-2.5 w-2.5 rounded-full bg-sun/80" />
                    <span className="h-2.5 w-2.5 rounded-full bg-tropic/80" />
                  </span>
                </div>
                <pre className="code-block p-5 text-sand/85">
{`# 1. descobre o protocolo
curl -s ${SITE_URL}/llms.txt

# 2. lê o manifesto
curl -s ${SITE_URL}/agents.json | jq .

# 3. consulta o estado on-chain
curl -s ${SITE_URL}/api/stats \\
  | jq '.masterChef | {poolLength, ownerRenounced}'

# 4. só então decide e assina
#    (nenhum endpoint executa transação por você)`}
                </pre>
                <div className="border-t border-sand/15 px-5 py-4">
                  <p className="font-mono text-[11px] leading-relaxed text-sand/55">
                    Sem chave privada no servidor. Sem custódia. O agente assina na própria wallet.
                  </p>
                </div>
              </div>
            </div>
          </div>
        </section>

        {/* -------------------------------------------------------------- */}
        {/* Security                                                       */}
        {/* -------------------------------------------------------------- */}
        <section id="seguranca" className="mx-auto max-w-7xl scroll-mt-24 px-5 py-20 sm:px-8 lg:py-28">
          <div className="grid grid-cols-1 gap-12 lg:grid-cols-[0.8fr_1.2fr]">
            <div>
              <p className="eyebrow text-coral">04 — segurança sem teatro</p>
              <h2 className="display mt-4 text-[clamp(2.3rem,4.6vw,4rem)]">
                Ainda não é
                <br />
                dinheiro real.
              </h2>
              <p className="copy mt-6">
                Nada aqui foi auditado por terceiros nem deployado com fundos. Os contratos têm testes
                unitários, limites duros e um histórico de decisões documentado — mas isso é o começo
                da conversa, não o fim.
              </p>
              <Link href={`${GITHUB_URL}/tree/main/contracts`} className="btn btn-primary mt-6" target="_blank" rel="noreferrer">
                Ler os contratos ↗
              </Link>
            </div>

            <ul className="space-y-3">
              {[
                ["13 testes Foundry passando", "Inclui prova de que o ataque de inflação de shares via doação é economicamente inviável."],
                ["Oráculo fail-closed", "Se o TWAP está velho, a valuation reverte. Nunca cai para o preço spot."],
                ["Colateral com LTV de 40%", "Threshold de liquidação em 50%, com buffers verificados no setter."],
                ["Saque nunca pausa", "O owner pode pausar depósitos, nunca bloquear retirada."],
                ["Sem proxy, sem upgrade", "Não existe chave que troque a lógica de um contrato em produção."],
                ["Auditoria externa pendente", "Este site não promete segurança: ele expõe o estado atual."],
              ].map(([title, text]) => (
                <li key={title} className="flex gap-4 rounded-2xl border border-ink/12 bg-white/40 p-5">
                  <span className="mt-1 flex h-6 w-6 shrink-0 items-center justify-center rounded-full bg-tropic text-xs text-sand">
                    ✓
                  </span>
                  <div>
                    <p className="font-semibold">{title}</p>
                    <p className="copy mt-1 text-sm">{text}</p>
                  </div>
                </li>
              ))}
            </ul>
          </div>
        </section>

        {/* -------------------------------------------------------------- */}
        {/* CTA                                                            */}
        {/* -------------------------------------------------------------- */}
        <section className="px-5 pb-20 sm:px-8 lg:pb-28">
          <div className="relative mx-auto max-w-7xl overflow-hidden rounded-[2rem] bg-tropic px-6 py-14 text-sand sm:px-12 lg:py-20">
            <div aria-hidden="true" className="dot-grid absolute inset-0 opacity-15" />
            <div className="relative z-10 grid grid-cols-1 items-center gap-8 lg:grid-cols-[1.2fr_0.8fr]">
              <div>
                <p className="eyebrow text-sun">próximo passo</p>
                <h2 className="display mt-4 text-[clamp(2.2rem,4.4vw,3.8rem)]">
                  O legado está no ar.
                  <br />
                  A nova camada, também.
                </h2>
                <p className="mt-4 max-w-xl leading-relaxed text-sand/75">
                  Explore o dashboard com os números lidos direto da BSC, ou plugue seu agente nos
                  manifestos e comece a monitorar.
                </p>
              </div>
              <div className="flex flex-wrap gap-3 lg:justify-end">
                <Link href="/dashboard" className="btn btn-sun">
                  Abrir dashboard
                </Link>
                <Link href="/llms.txt" className="btn btn-ghost border-sand/40 text-sand hover:bg-sand/10">
                  llms.txt
                </Link>
              </div>
            </div>
          </div>
        </section>
      </main>

      {/* ---------------------------------------------------------------- */}
      {/* Footer                                                            */}
      {/* ---------------------------------------------------------------- */}
      <footer className="border-t border-ink/15 bg-sand">
        <div className="mx-auto grid grid-cols-1 max-w-7xl gap-10 px-5 py-12 sm:px-8 md:grid-cols-[1.2fr_0.8fr_0.8fr]">
          <div>
            <div className="flex items-center gap-2.5">
              <span className="text-tropic">
                <FlipFlopMark />
              </span>
              <span className="display text-xl">gambiarra.</span>
            </div>
            <p className="copy mt-4 max-w-sm text-sm">
              Ressuscitando um DeFi abandonado com engenharia de verdade, código aberto e uma
              interface que agentes conseguem usar.
            </p>
            <p className="mt-4 font-mono text-[11px] uppercase tracking-widest text-ink-soft">
              built on {CHAIN.name} · chain id {CHAIN.id}
            </p>
          </div>

          <nav aria-label="Links do protocolo">
            <p className="eyebrow text-ink-soft">Protocolo</p>
            <ul className="mt-4 space-y-2 text-sm">
              <li><Link href="/dashboard" className="link-underline">Dashboard</Link></li>
              <li><Link href="/agents.json" className="link-underline">agents.json</Link></li>
              <li><Link href="/llms.txt" className="link-underline">llms.txt</Link></li>
              <li><Link href="/api/stats" className="link-underline">API de stats</Link></li>
            </ul>
          </nav>

          <div>
            <p className="eyebrow text-ink-soft">Código</p>
            <ul className="mt-4 space-y-2 text-sm">
              <li>
                <a href={GITHUB_URL} target="_blank" rel="noreferrer" className="link-underline">
                  GitHub da org ↗
                </a>
              </li>
              <li>
                <a
                  href={`${CHAIN.explorer}/address/${ADDRESSES.masterChef}`}
                  target="_blank"
                  rel="noreferrer"
                  className="link-underline"
                >
                  MasterChef no BscScan ↗
                </a>
              </li>
              <li>
                <a href="mailto:codingsh@pm.me" className="link-underline">
                  codingsh@pm.me
                </a>
              </li>
            </ul>
          </div>
        </div>

        <div className="border-t border-ink/12">
          <div className="mx-auto flex max-w-7xl flex-col gap-3 px-5 py-5 text-xs text-ink-soft sm:flex-row sm:items-center sm:justify-between sm:px-8">
            <p>© {new Date().getFullYear()} Gambiarra Finance. Código aberto, sem custódia.</p>
            <p className="font-mono uppercase tracking-widest">
              não é conselho financeiro · use por sua conta e risco
            </p>
          </div>
        </div>
      </footer>
    </div>
  );
}
