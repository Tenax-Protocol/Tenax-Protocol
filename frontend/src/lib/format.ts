import { formatUnits } from "viem";

/** A token amount (18 decimals) with a fixed number of fraction digits and thousands separators. */
export function formatToken(value: bigint, digits = 2): string {
  const number = Number(formatUnits(value, 18));
  return number.toLocaleString("en-US", { minimumFractionDigits: digits, maximumFractionDigits: digits });
}

export function formatEth(value: bigint, digits = 5): string {
  return `${formatToken(value, digits)} ETH`;
}

/** Basis points as a percentage. */
export function formatBps(bps: number | bigint, digits = 2): string {
  return `${(Number(bps) / 100).toFixed(digits)}%`;
}

/** A 1e18 fraction as a percentage. */
export function formatFraction(value: bigint, digits = 2): string {
  return `${(Number(formatUnits(value, 18)) * 100).toFixed(digits)}%`;
}

export function shortAddress(address: string): string {
  return `${address.slice(0, 6)}...${address.slice(-4)}`;
}

/** Seconds as "2d 04h", "3h 12m" or "5m 09s". */
export function formatDuration(seconds: number): string {
  const s = Math.max(0, Math.floor(seconds));
  const d = Math.floor(s / 86_400);
  const h = Math.floor((s % 86_400) / 3600);
  const m = Math.floor((s % 3600) / 60);
  const pad = (n: number) => String(n).padStart(2, "0");
  if (d > 0) return `${d}d ${pad(h)}h`;
  if (h > 0) return `${h}h ${pad(m)}m`;
  return `${m}m ${pad(s % 60)}s`;
}

/** A unix time as a UTC date and time. */
export function formatTime(timestamp: number): string {
  return `${new Date(timestamp * 1000).toISOString().slice(0, 16).replace("T", " ")} UTC`;
}

export function formatDate(timestamp: number): string {
  return new Date(timestamp * 1000).toISOString().slice(0, 10);
}
