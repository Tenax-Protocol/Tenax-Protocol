import type { Address } from "viem";

/** Eligibility constants, identical to BrierMath (skill is in 1e8 units). */
export const MIN_ROUNDS = 20n;
export const MIN_MEAN_SKILL = 300_000n;
export const Z_SQUARED_BPS = 26_896n;
export const BPS = 10_000n;

/** A participant's scored rounds over the test season. */
export interface ParticipantStats {
  account: Address;
  rounds: bigint;
  skillSum: bigint;
  skillSquares: bigint;
}

/**
 * The season reward tests of whitepaper section 5.6, applied to the whole test season: at least 20 scored rounds,
 * mean skill of at least 0.003 and z = sum / sqrt(sum of squares) of at least 1.64, computed without a square root
 * exactly as BrierMath.isEligible does.
 */
export function isEligible(stats: ParticipantStats): boolean {
  if (stats.rounds < MIN_ROUNDS || stats.skillSum <= 0n) return false;
  if (stats.skillSum < MIN_MEAN_SKILL * stats.rounds) return false;
  return stats.skillSum * stats.skillSum * BPS >= Z_SQUARED_BPS * stats.skillSquares;
}

export interface Allocation {
  account: Address;
  amount: bigint;
}

/**
 * Splits `budget` among eligible participants: half in equal parts, half in proportion to each one's skill over
 * the test season. Every amount rounds down, so the total never exceeds the budget.
 */
export function allocate(eligible: ParticipantStats[], budget: bigint): Allocation[] {
  if (eligible.length === 0) return [];
  const equalHalf = budget / 2n;
  const skillHalf = budget - equalHalf;
  const equalShare = equalHalf / BigInt(eligible.length);
  const totalSkill = eligible.reduce((sum, p) => sum + p.skillSum, 0n);
  return eligible.map((p) => ({ account: p.account, amount: equalShare + (skillHalf * p.skillSum) / totalSkill }));
}
