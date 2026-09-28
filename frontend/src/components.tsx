import { type ReactNode, useEffect, useRef, useState } from "react";
import { useConnect, useConnection, useConnectors, useDisconnect, useSwitchChain } from "wagmi";
import { type TxState, useNow } from "./hooks.js";
import { explorerAddress, explorerTx, network } from "./lib/config.js";
import { formatDuration, shortAddress } from "./lib/format.js";

/** A small gradient disc derived from an address, so each account is recognisable at a glance. */
export function Avatar({ address }: { address: string }) {
  const hue = parseInt(address.slice(2, 8), 16) % 360;
  const hue2 = (hue + 40 + (parseInt(address.slice(-4), 16) % 80)) % 360;
  return (
    <span
      className="avatar"
      style={{
        background: `linear-gradient(135deg, hsl(${hue} 55% 50%) 50%, hsl(${hue2} 60% 62%) 50%)`,
      }}
    />
  );
}

function useDismiss(open: boolean, close: () => void) {
  const ref = useRef<HTMLDivElement>(null);
  useEffect(() => {
    if (!open) return;
    const onClick = (e: MouseEvent) => {
      if (ref.current && !ref.current.contains(e.target as Node)) close();
    };
    const onKey = (e: KeyboardEvent) => e.key === "Escape" && close();
    document.addEventListener("mousedown", onClick);
    document.addEventListener("keydown", onKey);
    return () => {
      document.removeEventListener("mousedown", onClick);
      document.removeEventListener("keydown", onKey);
    };
  }, [open, close]);
  return ref;
}

export function ConnectButton() {
  const { address, chainId, isConnected } = useConnection();
  const connectors = useConnectors();
  const { mutate: connect, isPending } = useConnect();
  const { mutate: disconnect } = useDisconnect();
  const { mutate: switchChain } = useSwitchChain();
  const [open, setOpen] = useState(false);
  const [copied, setCopied] = useState(false);
  const ref = useDismiss(open, () => setOpen(false));

  if (isConnected && address && chainId !== network.chain.id) {
    return (
      <button className="button warning" onClick={() => switchChain({ chainId: network.chain.id })}>
        Switch to {network.chain.name}
      </button>
    );
  }

  return (
    <div className="menu-anchor" ref={ref}>
      {isConnected && address ? (
        <button className="wallet-chip" onClick={() => setOpen(!open)} aria-expanded={open}>
          <Avatar address={address} />
          <span className="mono">{shortAddress(address)}</span>
        </button>
      ) : (
        <button className="button primary" onClick={() => setOpen(!open)} disabled={isPending} aria-expanded={open}>
          {isPending ? "Connecting..." : "Connect wallet"}
        </button>
      )}
      {open && (
        <div className="menu" role="menu">
          {isConnected && address ? (
            <>
              <div className="menu-head">
                <Avatar address={address} />
                <div>
                  <div className="mono">{shortAddress(address)}</div>
                  <div className="muted small">{network.chain.name}</div>
                </div>
              </div>
              <button
                className="menu-item"
                onClick={() => {
                  void navigator.clipboard?.writeText(address);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 1500);
                }}
              >
                {copied ? "Copied" : "Copy address"}
              </button>
              <a className="menu-item" href={explorerAddress(address)} target="_blank" rel="noreferrer">
                View on explorer
              </a>
              <button
                className="menu-item danger"
                onClick={() => {
                  disconnect();
                  setOpen(false);
                }}
              >
                Disconnect
              </button>
            </>
          ) : (
            <>
              <div className="menu-title">Connect a wallet</div>
              {connectors.map((connector) => (
                <button
                  key={connector.uid}
                  className="menu-item"
                  onClick={() => {
                    connect({ connector, chainId: network.chain.id });
                    setOpen(false);
                  }}
                >
                  {connector.name === "Injected" ? "Browser wallet" : connector.name}
                </button>
              ))}
              <p className="menu-note">Network: {network.chain.name}</p>
            </>
          )}
        </div>
      )}
    </div>
  );
}

export function PageHeader({ title, children }: { title: ReactNode; children?: ReactNode }) {
  return (
    <header className="page-header">
      <h1>{title}</h1>
      {children && <p className="lead">{children}</p>}
    </header>
  );
}

export function Card({
  title,
  children,
  aside,
  className,
}: {
  title?: ReactNode;
  children: ReactNode;
  aside?: ReactNode;
  className?: string;
}) {
  return (
    <section className={`card${className ? ` ${className}` : ""}`}>
      {(title || aside) && (
        <header className="card-header">
          {title && <h2>{title}</h2>}
          {aside}
        </header>
      )}
      {children}
    </section>
  );
}

export function Stat({ label, value, hint }: { label: string; value: ReactNode; hint?: ReactNode }) {
  return (
    <div className="stat">
      <span className="stat-label">{label}</span>
      <span className="stat-value">{value}</span>
      {hint && <span className="stat-hint">{hint}</span>}
    </div>
  );
}

export function Countdown({ to }: { to: number }) {
  const now = useNow();
  return <span className="num">{formatDuration(to - now)}</span>;
}

export function AssetBadge({ symbol }: { symbol: string }) {
  return <span className={`asset-badge asset-${symbol.toLowerCase()}`}>{symbol === "BTC" ? "₿" : "Ξ"}</span>;
}

/** A horizontal gauge from 0 to 1, for probabilities. */
export function Meter({ value, label }: { value: number; label?: string }) {
  return (
    <div className="meter" role="meter" aria-valuemin={0} aria-valuemax={1} aria-valuenow={value} aria-label={label}>
      <div className="meter-fill" style={{ width: `${Math.min(1, Math.max(0, value)) * 100}%` }} />
    </div>
  );
}

export function TxStatus({ state }: { state: TxState }) {
  if (state.status === "idle") return null;
  return (
    <p className={`tx tx-${state.status}`}>
      {state.status === "pending" && <span className="spinner" />}
      {state.message}
      {state.hash && (
        <>
          {" "}
          <a href={explorerTx(state.hash)} target="_blank" rel="noreferrer">
            View transaction
          </a>
        </>
      )}
    </p>
  );
}

export function ConnectPrompt({ what }: { what: string }) {
  return (
    <section className="card connect-prompt">
      <h2>Connect a wallet to {what}</h2>
      <p className="muted">Browser wallets and Coinbase Wallet are supported, on {network.chain.name}.</p>
      <ConnectButton />
    </section>
  );
}

export function Loading() {
  return (
    <div className="loading" role="status">
      <span className="spinner" />
      Loading
    </div>
  );
}
