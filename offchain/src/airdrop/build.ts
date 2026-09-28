import type { Address, Hex } from "viem";
import { forecastRegistryAbi } from "../abi/index.js";
import { allocate, isEligible, type ParticipantStats } from "../lib/airdrop.js";
import type { Context } from "../lib/context.js";
import { buildTree, leafHash, verifyProof } from "../lib/merkle.js";
import { participants } from "../lib/participants.js";

/** The airdrop bucket: 10,000,000 TENAX. */
export const AIRDROP_BUDGET = 10_000_000n * 10n ** 18n;

export interface Recipient {
  account: Address;
  amount: string;
  rounds: string;
  skillSum: string;
  proof: Hex[];
}

export interface AirdropTree {
  network: string;
  seasons: number[];
  budget: string;
  total: string;
  root: Hex;
  participants: number;
  pending: Address[];
  recipients: Recipient[];
}

/**
 * Builds the airdrop from the test season: every participant's scored rounds over `seasons` are summed, the
 * eligibility tests are applied to the whole test season, the budget is split half equally and half by skill, and a
 * Merkle tree of the allocations is built with a proof per recipient. Participants with unsettled commitments are
 * reported, since their stats are not final until settled.
 */
export async function buildAirdrop(ctx: Context, seasons: number[], budget = AIRDROP_BUDGET): Promise<AirdropTree> {
  const registry = ctx.deployment.contracts.registry;
  const accounts = await participants(ctx);
  const stats: ParticipantStats[] = [];
  const pending: Address[] = [];

  for (const account of accounts) {
    const total: ParticipantStats = { account, rounds: 0n, skillSum: 0n, skillSquares: 0n };
    for (const season of seasons) {
      const s = await ctx.publicClient.readContract({
        address: registry,
        abi: forecastRegistryAbi,
        functionName: "seasonStats",
        args: [account, BigInt(season)],
      });
      total.rounds += BigInt(s.rounds);
      total.skillSum += s.skillSum;
      total.skillSquares += s.skillSquares;
    }
    const unsettled = await ctx.publicClient.readContract({
      address: registry,
      abi: forecastRegistryAbi,
      functionName: "pendingCount",
      args: [account],
    });
    if (unsettled > 0n) pending.push(account);
    stats.push(total);
  }

  const eligible = stats.filter(isEligible);
  const allocations = allocate(eligible, budget);
  if (allocations.length === 0) {
    throw new Error(`no participant of seasons ${seasons.join(", ")} passes the tests`);
  }
  const leaves = allocations.map((a) => leafHash(a.account, a.amount));
  const tree = buildTree(leaves);
  const recipients = allocations.map((a, i): Recipient => {
    const proof = tree.proof(i);
    if (!verifyProof(leaves[i]!, proof, tree.root)) throw new Error(`proof ${i} does not verify`);
    const s = eligible[i]!;
    return {
      account: a.account,
      amount: a.amount.toString(),
      rounds: s.rounds.toString(),
      skillSum: s.skillSum.toString(),
      proof,
    };
  });

  return {
    network: ctx.network,
    seasons,
    budget: budget.toString(),
    total: allocations.reduce((sum, a) => sum + a.amount, 0n).toString(),
    root: tree.root,
    participants: accounts.length,
    pending,
    recipients,
  };
}
