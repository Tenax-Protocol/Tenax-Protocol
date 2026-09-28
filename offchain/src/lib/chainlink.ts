import { type Address, type PublicClient, zeroAddress } from "viem";
import { iAggregatorV3Abi } from "../abi/index.js";

/** Reads the time of a Chainlink round, or null when the round does not exist. */
export type ReadRound = (roundId: bigint) => Promise<bigint | null>;

const PHASE_SHIFT = 64n;
const AGGREGATOR_MASK = (1n << PHASE_SHIFT) - 1n;

/**
 * Finds the round that was active at `timestamp`, in the form the OracleAdapter accepts as a hint: a round whose
 * time is at or before `timestamp` and that is either the latest round or followed by a round after `timestamp`.
 *
 * Proxy round ids pack a phase in the high 64 bits and the aggregator round in the low 64 bits; rounds are
 * contiguous within a phase. Returns null when no provable round exists: before the first round, or inside the
 * last round of an old phase, which has no successor to prove it ended.
 */
export async function findRoundAt(read: ReadRound, latestId: bigint, timestamp: bigint): Promise<bigint | null> {
  const latestTime = await read(latestId);
  if (latestTime !== null && latestTime <= timestamp) return latestId;

  let phase = latestId >> PHASE_SHIFT;
  let high = latestId & AGGREGATOR_MASK; // a round of this phase that started after `timestamp`
  for (;;) {
    const base = phase << PHASE_SHIFT;
    const first = await read(base | 1n);
    if (first !== null && first <= timestamp) {
      let low = 1n; // invariant: time(low) <= timestamp < time(high)
      while (high - low > 1n) {
        const mid = (low + high) / 2n;
        const time = await read(base | mid);
        if (time !== null && time <= timestamp) low = mid;
        else high = mid;
      }
      return base | low;
    }
    if (phase === 0n) return null;
    phase -= 1n;
    high = await lastRoundOfPhase(read, phase);
    if (high === 0n) return null;
    const lastTime = await read((phase << PHASE_SHIFT) | high);
    // The last round of an old phase has no successor, so it cannot be proven active.
    if (lastTime === null || lastTime <= timestamp) return null;
  }
}

/** Highest existing aggregator round of `phase`, or 0 if the phase has none. */
async function lastRoundOfPhase(read: ReadRound, phase: bigint): Promise<bigint> {
  const base = phase << PHASE_SHIFT;
  if ((await read(base | 1n)) === null) return 0n;
  let known = 1n;
  let probe = 2n;
  while ((await read(base | probe)) !== null) {
    known = probe;
    probe *= 2n;
  }
  while (probe - known > 1n) {
    const mid = (known + probe) / 2n;
    if ((await read(base | mid)) !== null) known = mid;
    else probe = mid;
  }
  return known;
}

/** Which timestamp of a round marks it: price feeds use `updatedAt`, the sequencer uptime feed `startedAt`. */
export type RoundTime = "updatedAt" | "startedAt";

export function feedReader(client: PublicClient, feed: Address, field: RoundTime): ReadRound {
  return async (roundId) => {
    try {
      const [, , startedAt, updatedAt] = await client.readContract({
        address: feed,
        abi: iAggregatorV3Abi,
        functionName: "getRoundData",
        args: [roundId],
      });
      const time = field === "updatedAt" ? updatedAt : startedAt;
      return time === 0n ? null : time;
    } catch {
      return null;
    }
  };
}

/** Round hint for `feed` at `timestamp`; zero for a disabled feed. Null when no provable round exists. */
export async function roundHint(
  client: PublicClient,
  feed: Address,
  timestamp: bigint,
  field: RoundTime,
): Promise<bigint | null> {
  if (feed === zeroAddress) return 0n;
  const [latestId] = await client.readContract({ address: feed, abi: iAggregatorV3Abi, functionName: "latestRoundData" });
  return findRoundAt(feedReader(client, feed, field), latestId, timestamp);
}
