import { type Address, encodeAbiParameters, type Hex, hexToBytes, keccak256 } from "viem";

/**
 * Commit-reveal helpers. The salt of each commitment is derived from one wallet signature (the "forecast key")
 * and the round, so a participant never has to store anything: signing the same message again on any device gives
 * the same salts, and the forecast itself is recovered at reveal time by trying every value against the
 * commitment stored on chain. Wallets whose signatures are not deterministic (some smart wallets) rely on the key
 * kept in the browser instead.
 */

/** Message signed once to derive every forecast salt of an account on one registry. */
export function forecastKeyMessage(account: Address, chainId: number, registry: Address): string {
  return [
    "Tenax Protocol forecast key",
    "",
    "Signing this message derives the secret salts that hide your forecasts until you reveal them.",
    "It does not send a transaction or cost anything. Never sign it on a site other than Tenax Protocol.",
    "",
    `Account: ${account.toLowerCase()}`,
    `Chain: ${chainId}`,
    `Registry: ${registry.toLowerCase()}`,
  ].join("\n");
}

/** The forecast key: a hash of the signature, so the signature itself never needs to be kept. */
export function forecastKey(signature: Hex): Hex {
  return keccak256(signature);
}

/** Salt of the commitment for `asset` and `round`. */
export function deriveSalt(key: Hex, asset: bigint, round: bigint): Hex {
  return keccak256(
    encodeAbiParameters([{ type: "bytes32" }, { type: "uint256" }, { type: "uint256" }], [key, asset, round]),
  );
}

export interface CommitmentContext {
  chainId: number;
  registry: Address;
  asset: bigint;
  round: bigint;
  participant: Address;
}

function commitmentPreimage(ctx: CommitmentContext, forecast: bigint, salt: Hex): Hex {
  return encodeAbiParameters(
    [
      { type: "uint256" },
      { type: "address" },
      { type: "uint256" },
      { type: "uint256" },
      { type: "address" },
      { type: "uint256" },
      { type: "bytes32" },
    ],
    [BigInt(ctx.chainId), ctx.registry, ctx.asset, ctx.round, ctx.participant, forecast, salt],
  );
}

/** Same encoding as ForecastRegistry.commitmentHash. */
export function commitmentHash(ctx: CommitmentContext, forecast: bigint, salt: Hex): Hex {
  return keccak256(commitmentPreimage(ctx, forecast, salt));
}

/**
 * Finds the forecast (0 to 10,000 basis points) behind a stored commitment, or null if the salt does not match. The
 * encoding is built once and only the forecast word is rewritten, so even the last value is found in well under a
 * second.
 */
export function recoverForecast(ctx: CommitmentContext, stored: Hex, salt: Hex): bigint | null {
  const bytes = hexToBytes(commitmentPreimage(ctx, 0n, salt));
  const target = stored.toLowerCase();
  for (let forecast = 0; forecast <= 10_000; forecast++) {
    // The forecast is the sixth word; values up to 10,000 fit in its last two bytes.
    bytes[190] = forecast >> 8;
    bytes[191] = forecast & 0xff;
    if (keccak256(bytes) === target) return BigInt(forecast);
  }
  return null;
}

/** Schedule of round `round`: it opens at genesis + round days; the windows are read from the registry. */
export function roundSchedule(genesis: number, round: bigint, submissionWindow: number, revealWindow: number) {
  const open = genesis + Number(round) * 86_400;
  const commitEnd = open + submissionWindow;
  const resolveTime = commitEnd + 86_400;
  return { open, commitEnd, resolveTime, revealEnd: resolveTime + revealWindow };
}

/** Round currently accepting commitments (or about to), as ForecastRegistry.currentRound computes it. */
export function currentRound(genesis: number, now: number): bigint | null {
  if (now < genesis) return null;
  return BigInt(Math.floor((now - genesis) / 86_400));
}

/** A 1e18 fraction in basis points, rounded half up like BrierMath.toBps. */
export function toBps(fraction: bigint): number {
  return Number((fraction * 10_000n + 5n * 10n ** 17n) / 10n ** 18n);
}
