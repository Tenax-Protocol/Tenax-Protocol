import { MAX_LOCK, WEEK } from "./config.js";

/** Mirrors of the vote escrow's arithmetic (contracts/src/escrow/EscrowMath.sol). */

/** Unlock times are rounded down to whole weeks. */
export function roundDownToWeek(timestamp: number): number {
  return Math.floor(timestamp / WEEK) * WEEK;
}

/** veTENAX of a lock at `now`: slope (amount / 104 weeks, rounded down) times the time left. */
export function veBalance(amount: bigint, end: number, now: number): bigint {
  if (end <= now) return 0n;
  const slope = amount / BigInt(MAX_LOCK);
  return slope * BigInt(end - now);
}

/** Penalty to exit `voluntary` tokens early: voluntary * min(time left / 104 weeks, 50%), rounded up. */
export function earlyExitPenalty(voluntary: bigint, remaining: number): bigint {
  const capped = BigInt(Math.min(Math.max(remaining, 0), MAX_LOCK / 2));
  const max = BigInt(MAX_LOCK);
  return (voluntary * capped + max - 1n) / max;
}

/** Smallest amount that gives at least `ve` veTENAX when locked until `end`. */
export function amountForVe(ve: bigint, end: number, now: number): bigint {
  const remaining = BigInt(end - now);
  if (remaining <= 0n) return 0n;
  // slope = amount / MAX_LOCK must satisfy slope * remaining >= ve.
  const slope = (ve + remaining - 1n) / remaining;
  return slope * BigInt(MAX_LOCK);
}
