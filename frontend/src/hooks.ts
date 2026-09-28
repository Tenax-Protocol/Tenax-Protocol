import { useQueryClient } from "@tanstack/react-query";
import { useCallback, useEffect, useState } from "react";
import type { Address, Hash, Hex, WalletClient } from "viem";
import { useConnection, useSignMessage, useWalletClient } from "wagmi";
import { publicClient } from "./lib/client.js";
import { contracts, network } from "./lib/config.js";
import { errorMessage } from "./lib/errors.js";
import { forecastKey, forecastKeyMessage } from "./lib/forecast.js";

/** Current unix time, updated every second. */
export function useNow(): number {
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  useEffect(() => {
    const id = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(id);
  }, []);
  return now;
}

/** The page named in the URL hash (#/forecast), which works on any static host. */
export function useRoute(): string {
  const read = () => window.location.hash.replace(/^#\/?/, "").split("?")[0] || "overview";
  const [route, setRoute] = useState(read);
  useEffect(() => {
    const onChange = () => {
      setRoute(read());
      window.scrollTo(0, 0);
    };
    window.addEventListener("hashchange", onChange);
    return () => window.removeEventListener("hashchange", onChange);
  }, []);
  return route;
}

/** The connected account, when it is on the right network. */
export function useAccount(): { address?: Address; wrongNetwork: boolean } {
  const { address, chainId, isConnected } = useConnection();
  if (!isConnected || !address) return { wrongNetwork: false };
  return chainId === network.chain.id ? { address, wrongNetwork: false } : { wrongNetwork: true };
}

const keyStorage = (account: Address) =>
  `tenax:forecast-key:${network.chain.id}:${contracts.registry.toLowerCase()}:${account.toLowerCase()}`;

/**
 * The forecast key of `account`: kept in this browser once derived, and derived from a wallet signature when
 * missing. Signing again on another device gives the same key for wallets with deterministic signatures.
 */
export function useForecastKey(account?: Address) {
  const { mutateAsync: signMessage } = useSignMessage();
  const stored = (): Hex | undefined => {
    if (!account) return undefined;
    try {
      return (localStorage.getItem(keyStorage(account)) as Hex | null) ?? undefined;
    } catch {
      return undefined;
    }
  };
  const obtain = useCallback(async (): Promise<Hex> => {
    if (!account) throw new Error("Connect a wallet first.");
    const existing = stored();
    if (existing) return existing;
    const signature = await signMessage({ message: forecastKeyMessage(account, network.chain.id, contracts.registry) });
    const key = forecastKey(signature);
    try {
      localStorage.setItem(keyStorage(account), key);
    } catch {
      // Private browsing: the key is simply derived again next time.
    }
    return key;
  }, [account, signMessage]);
  return { obtain, key: stored() };
}

export type TxState = { status: "idle" | "pending" | "done" | "error"; message?: string; hash?: Hash };

/**
 * Runs a transaction from the connected wallet, waits for it and refreshes every query afterwards. The callback
 * receives the wallet client and returns the transaction hash.
 */
export function useTx() {
  const { data: walletClient } = useWalletClient();
  const queryClient = useQueryClient();
  const [state, setState] = useState<TxState>({ status: "idle" });

  const run = useCallback(
    async (send: (wallet: WalletClient) => Promise<Hash>, done?: string): Promise<boolean> => {
      if (!walletClient) {
        setState({ status: "error", message: "Connect a wallet on Base Sepolia first." });
        return false;
      }
      setState({ status: "pending", message: "Confirm in your wallet..." });
      try {
        const hash = await send(walletClient);
        setState({ status: "pending", message: "Waiting for confirmation...", hash });
        const receipt = await publicClient.waitForTransactionReceipt({ hash });
        if (receipt.status !== "success") throw new Error("The transaction reverted.");
        setState({ status: "done", message: done ?? "Done.", hash });
        await queryClient.invalidateQueries();
        return true;
      } catch (error) {
        setState({ status: "error", message: errorMessage(error) });
        return false;
      }
    },
    [walletClient, queryClient],
  );

  return { run, state, reset: () => setState({ status: "idle" }) };
}
