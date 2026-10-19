"use client";

import { useCallback, useEffect, useState } from "react";
import {
  createPublicClient,
  createWalletClient,
  custom,
  http,
  parseAbi,
  type Address,
  type EIP1193Provider,
  type PublicClient,
} from "viem";
import { bsc } from "viem/chains";
import { ADDRESSES, CHAIN } from "@/lib/protocol";
import { formatTokenAmount } from "@/lib/format";

const erc20Abi = parseAbi([
  "function balanceOf(address account) view returns (uint256)",
  "function decimals() view returns (uint8)",
]);

const masterChefAbi = parseAbi([
  "function userInfo(uint256 pid, address user) view returns (uint256 amount, uint256 rewardDebt)",
  "function pendingGamb(uint256 pid, address user) view returns (uint256)",
]);

/**
 * Client-side RPC candidates. In `next dev` the local Anvil fork wins; if it is
 * not running, the panel silently falls back to a public BSC RPC.
 */
const RPC_URLS = [
  process.env.NEXT_PUBLIC_RPC_URL,
  process.env.NODE_ENV === "development" ? "http://127.0.0.1:8545" : undefined,
  "https://bsc-dataseed.binance.org",
].filter((url, index, all): url is string => Boolean(url) && all.indexOf(url) === index);

type InjectedProvider = EIP1193Provider & {
  on?: (event: string, handler: (...args: never[]) => void) => void;
  removeListener?: (event: string, handler: (...args: never[]) => void) => void;
};

type StakedPosition = {
  pid: number;
  amount: bigint;
  pending: bigint;
  decimals: number;
};

type Position = {
  bnb: bigint;
  gamb: bigint;
  gambDecimals: number;
  staked: StakedPosition[];
};

function injectedProvider(): InjectedProvider | null {
  if (typeof window === "undefined") return null;
  return (window as unknown as { ethereum?: InjectedProvider }).ethereum ?? null;
}

function shortAddress(address: string) {
  return `${address.slice(0, 6)}…${address.slice(-4)}`;
}

function formatAmount(value: bigint, decimals: number) {
  return formatTokenAmount(value, decimals, 4);
}

async function loadPosition(client: PublicClient, account: Address): Promise<Position> {
  const gamb = { address: ADDRESSES.gambToken, abi: erc20Abi } as const;
  const lp = { address: ADDRESSES.gambWbnbLp, abi: erc20Abi } as const;
  const masterChef = { address: ADDRESSES.masterChef, abi: masterChefAbi } as const;

  const [bnb, gambBalance, gambDecimals, lpDecimals, info16, info25, pending16, pending25] = await Promise.all([
    client.getBalance({ address: account }),
    client.readContract({ ...gamb, functionName: "balanceOf", args: [account] }),
    client.readContract({ ...gamb, functionName: "decimals" }),
    client.readContract({ ...lp, functionName: "decimals" }),
    client.readContract({ ...masterChef, functionName: "userInfo", args: [16n, account] }),
    client.readContract({ ...masterChef, functionName: "userInfo", args: [25n, account] }),
    client.readContract({ ...masterChef, functionName: "pendingGamb", args: [16n, account] }),
    client.readContract({ ...masterChef, functionName: "pendingGamb", args: [25n, account] }),
  ]);

  return {
    bnb,
    gamb: gambBalance,
    gambDecimals,
    staked: [
      { pid: 16, amount: info16[0], pending: pending16, decimals: lpDecimals },
      { pid: 25, amount: info25[0], pending: pending25, decimals: lpDecimals },
    ],
  };
}

export function WalletPanel() {
  const [client, setClient] = useState<PublicClient | null>(null);
  const [rpcLabel, setRpcLabel] = useState("conectando…");
  const [rpcDown, setRpcDown] = useState(false);
  const [account, setAccount] = useState<Address | null>(null);
  const [walletChainId, setWalletChainId] = useState<number | null>(null);
  const [position, setPosition] = useState<Position | null>(null);
  const [loading, setLoading] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  useEffect(() => {
    let cancelled = false;

    (async () => {
      for (const url of RPC_URLS) {
        try {
          const candidate = createPublicClient({
            chain: bsc,
            transport: http(url, { timeout: 4_000, retryCount: 0 }),
          });
          await candidate.getChainId();
          if (cancelled) return;
          const isFork = url.includes("127.0.0.1") || url.includes("localhost");
          setClient(candidate);
          setRpcLabel(isFork ? "fork local" : "RPC público");
          setRpcDown(false);
          return;
        } catch {
          // try the next endpoint
        }
      }

      if (!cancelled) {
        setRpcDown(true);
        setRpcLabel("RPC indisponível");
      }
    })();

    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    const provider = injectedProvider();
    if (!provider?.on) return;

    const onAccountsChanged = (...args: never[]) => {
      const accounts = args[0] as unknown as Address[] | undefined;
      setLoading(Boolean(accounts?.[0]));
      setAccount(accounts?.[0] ?? null);
      setPosition(null);
    };

    provider.on("accountsChanged", onAccountsChanged);
    return () => provider.removeListener?.("accountsChanged", onAccountsChanged);
  }, []);

  const refresh = useCallback(async () => {
    if (!client || !account) return;

    setLoading(true);
    setError(null);
    try {
      setPosition(await loadPosition(client, account));
    } catch {
      setError("Não foi possível ler os saldos agora. Tente novamente.");
      setPosition(null);
    } finally {
      setLoading(false);
    }
  }, [client, account]);

  useEffect(() => {
    if (!client || !account) return;
    let cancelled = false;

    (async () => {
      try {
        const next = await loadPosition(client, account);
        if (!cancelled) {
          setPosition(next);
          setError(null);
        }
      } catch {
        if (!cancelled) {
          setError("Não foi possível ler os saldos agora. Tente novamente.");
          setPosition(null);
        }
      } finally {
        if (!cancelled) setLoading(false);
      }
    })();

    return () => {
      cancelled = true;
    };
  }, [account, client]);

  const connect = useCallback(async () => {
    const provider = injectedProvider();
    if (!provider) {
      setNotice("Nenhuma carteira injetada encontrada. Instale a MetaMask ou use um navegador com wallet.");
      return;
    }

    setNotice(null);
    setError(null);

    try {
      const wallet = createWalletClient({ chain: bsc, transport: custom(provider) });
      const [selected] = await wallet.requestAddresses();
      if (!selected) throw new Error("no account");

      setLoading(true);
      setAccount(selected);

      const chainIdHex = (await provider.request({ method: "eth_chainId" })) as `0x${string}`;
      setWalletChainId(Number(BigInt(chainIdHex)));
    } catch {
      setLoading(false);
      setNotice("A conexão com a carteira foi recusada.");
    }
  }, []);

  const switchToBsc = useCallback(async () => {
    const provider = injectedProvider();
    if (!provider) return;

    setError(null);
    try {
      const wallet = createWalletClient({ chain: bsc, transport: custom(provider) });
      try {
        await wallet.switchChain({ id: bsc.id });
      } catch {
        await wallet.addChain({ chain: bsc });
        await wallet.switchChain({ id: bsc.id });
      }
      setWalletChainId(bsc.id);
    } catch {
      setError("Não foi possível trocar para a BSC. Troque manualmente na carteira.");
    }
  }, []);

  const disconnect = useCallback(() => {
    setAccount(null);
    setPosition(null);
    setError(null);
    setNotice(null);
    setLoading(false);
  }, []);

  const wrongChain = walletChainId !== null && walletChainId !== bsc.id;

  return (
    <section className="card p-6 sm:p-8" aria-labelledby="wallet-title">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <div>
          <p className="eyebrow text-coral">carteira · leitura via viem</p>
          <h2 id="wallet-title" className="display mt-2 text-2xl">
            Sua posição
          </h2>
        </div>
        <span className="chip text-ink-soft">
          <span
            className={`inline-block h-2 w-2 rounded-full ${
              rpcDown ? "bg-coral" : rpcLabel === "fork local" ? "bg-ocean" : "bg-tropic"
            }`}
          />
          {rpcLabel}
        </span>
      </div>

      {!account ? (
        <div className="mt-5 flex flex-col gap-4 sm:flex-row sm:items-center sm:justify-between">
          <p className="copy max-w-xl text-sm">
            Conecte a carteira para ler seu BNB, seu GAMB e o LP GAMB/WBNB travado nos pools{" "}
            <strong className="text-ink">16</strong> e <strong className="text-ink">25</strong> do MasterChef.
            Nenhuma transação é assinada por esta página.
          </p>
          <button type="button" className="btn btn-primary shrink-0 px-5 py-2.5 text-xs" onClick={connect}>
            Conectar carteira
          </button>
        </div>
      ) : (
        <>
          <div className="mt-5 flex flex-wrap items-center gap-3">
            <span className="chip bg-ink text-sand">{shortAddress(account)}</span>
            {wrongChain ? (
              <>
                <span className="chip border-coral/40 bg-coral/10 text-coral">
                  rede {walletChainId} · troque para BSC
                </span>
                <button type="button" className="btn btn-ghost px-3 py-1.5 text-xs" onClick={switchToBsc}>
                  Trocar para BSC
                </button>
              </>
            ) : (
              <span className="chip text-ink-soft">{CHAIN.shortName}</span>
            )}
            <div className="ml-auto flex gap-2">
              <button
                type="button"
                className="btn btn-ghost px-3 py-1.5 text-xs"
                onClick={() => void refresh()}
                disabled={loading}
              >
                {loading ? "lendo…" : "Atualizar"}
              </button>
              <button type="button" className="btn btn-ghost px-3 py-1.5 text-xs" onClick={disconnect}>
                Desconectar
              </button>
            </div>
          </div>

          <dl className="mt-6 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-4">
            {[
              { label: "BNB", value: position ? formatAmount(position.bnb, 18) : "—" },
              { label: "GAMB", value: position ? formatAmount(position.gamb, position.gambDecimals) : "—" },
              ...(position?.staked ?? []).map((stake) => ({
                label: `LP no pool ${stake.pid}`,
                value: formatAmount(stake.amount, stake.decimals),
              })),
            ].map((item) => (
              <div key={item.label} className="rounded-xl border border-ink/15 bg-sand/60 px-4 py-3">
                <dt className="font-mono text-[10px] uppercase tracking-widest text-ink-soft">{item.label}</dt>
                <dd className="display mt-1 break-words text-xl">{item.value}</dd>
              </div>
            ))}
          </dl>

          {position && position.staked.some((stake) => stake.pending > 0n) && (
            <p className="mt-3 font-mono text-[11px] uppercase tracking-widest text-ink-soft">
              pending GAMB · pool 16: {formatAmount(position.staked[0].pending, 18)} · pool 25:{" "}
              {formatAmount(position.staked[1].pending, 18)}
            </p>
          )}

          {error && <p className="mt-3 text-sm font-semibold text-coral">{error}</p>}
        </>
      )}

      {notice && <p className="mt-3 text-sm font-semibold text-coral">{notice}</p>}
      {rpcDown && (
        <p className="mt-3 text-xs text-ink-soft">
          Nenhum RPC respondeu. Se estiver em dev, suba o fork com{" "}
          <code className="rounded bg-ink/6 px-1.5 py-0.5 font-mono text-[11px]">make fork</code> em{" "}
          <code className="rounded bg-ink/6 px-1.5 py-0.5 font-mono text-[11px]">contracts/</code>.
        </p>
      )}
    </section>
  );
}
