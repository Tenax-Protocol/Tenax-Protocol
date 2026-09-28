/** Season statistics as the registry keeps them: skill in 1e8 units (1.0 = 100,000,000). */
export interface Stats {
  rounds: bigint;
  skillSum: bigint;
  skillSquares: bigint;
}

export const SKILL_ONE = 100_000_000;

/** Mean skill per scored round, as a plain number. */
export function meanSkill(s: Stats): number {
  return s.rounds === 0n ? 0 : Number(s.skillSum) / Number(s.rounds) / SKILL_ONE;
}

/** Significance of the skill: z = sum / sqrt(sum of squares). */
export function zScore(s: Stats): number {
  if (s.skillSquares === 0n) return 0;
  return Number(s.skillSum) / Math.sqrt(Number(s.skillSquares));
}

/** The season reward tests over a window (BrierMath.isEligible), with `seasonRounds` counted in the season itself. */
export function passesTests(seasonRounds: bigint, window: Stats): boolean {
  if (seasonRounds < 20n || window.skillSum <= 0n) return false;
  if (window.skillSum < 300_000n * window.rounds) return false;
  return window.skillSum * window.skillSum * 10_000n >= 26_896n * window.skillSquares;
}

export function addStats(a: Stats, b: Stats): Stats {
  return {
    rounds: a.rounds + b.rounds,
    skillSum: a.skillSum + b.skillSum,
    skillSquares: a.skillSquares + b.skillSquares,
  };
}

export const EMPTY_STATS: Stats = { rounds: 0n, skillSum: 0n, skillSquares: 0n };

/** Brier score of a forecast in basis points, in 1e8 units. */
export function brier(forecastBps: number, outcome: boolean): number {
  const distance = outcome ? 10_000 - forecastBps : forecastBps;
  return distance * distance;
}

/** Skill of a forecast against the round's base rate (BrierMath.skill), as a plain number. */
export function skillOf(forecastBps: number, baseRateBps: number, outcome: boolean): number {
  return (brier(baseRateBps, outcome) - brier(forecastBps, outcome)) / SKILL_ONE;
}
