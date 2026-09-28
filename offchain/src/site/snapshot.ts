import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { forecastRegistryAbi } from "../abi/index.js";
import { type Context, createContext, log, repoRoot } from "../lib/context.js";
import { participants } from "../lib/participants.js";

/**
 * Builds the leaderboard snapshot the dApp serves as a static file: every participant with their reputation and
 * their scored rounds, skill and contribution in each season so far. The site is static and public RPCs limit log
 * queries, so browsers read this file instead of scanning events; the site workflow refreshes it every hour.
 */

export interface SnapshotSeason {
  season: number;
  rounds: number;
  skillSum: string;
  skillSquares: string;
  contribution: string;
}

export interface Snapshot {
  network: string;
  chainId: number;
  block: string;
  updatedAt: string;
  currentSeason: number;
  participants: { account: string; reputation: string; seasons: SnapshotSeason[] }[];
}

const DAY = 86_400n;
const SEASON_LENGTH = 30n * DAY;

export async function buildSnapshot(ctx: Context): Promise<Snapshot> {
  const registry = ctx.deployment.contracts.registry;
  const block = await ctx.publicClient.getBlock();
  const elapsed = block.timestamp > ctx.deployment.genesis ? block.timestamp - ctx.deployment.genesis : 0n;
  const currentSeason = Number(elapsed / SEASON_LENGTH);
  const accounts = await participants(ctx);

  const result: Snapshot["participants"] = [];
  for (const account of accounts) {
    const calls = [
      { address: registry, abi: forecastRegistryAbi, functionName: "reputation", args: [account] } as const,
      ...Array.from({ length: currentSeason + 1 }, (_, season) => ({
        address: registry,
        abi: forecastRegistryAbi,
        functionName: "seasonStats",
        args: [account, BigInt(season)],
      }) as const),
    ];
    const [reputation, ...stats] = await ctx.publicClient.multicall({ contracts: calls, allowFailure: false });
    result.push({
      account,
      reputation: (reputation as bigint).toString(),
      seasons: (stats as { rounds: number; skillSum: bigint; skillSquares: bigint; contribution: bigint }[]).map(
        (s, season) => ({
          season,
          rounds: s.rounds,
          skillSum: s.skillSum.toString(),
          skillSquares: s.skillSquares.toString(),
          contribution: s.contribution.toString(),
        }),
      ),
    });
  }

  return {
    network: ctx.network,
    chainId: ctx.deployment.chainId,
    block: block.number.toString(),
    updatedAt: new Date(Number(block.timestamp) * 1000).toISOString(),
    currentSeason,
    participants: result,
  };
}

if (process.argv[1]?.endsWith("snapshot.ts")) {
  const { values } = parseArgs({
    options: { network: { type: "string", default: "base-sepolia" }, out: { type: "string" } },
  });
  const rpcUrl = process.env.RPC_URL;
  if (!rpcUrl) {
    console.error("RPC_URL must be set");
    process.exit(1);
  }
  const ctx = await createContext({ network: values.network!, rpcUrl });
  const snapshot = await buildSnapshot(ctx);
  const out = values.out ?? join(repoRoot, "frontend", "public", "data", `${ctx.network}.json`);
  mkdirSync(dirname(out), { recursive: true });
  writeFileSync(out, `${JSON.stringify(snapshot, null, 2)}\n`);
  log(`snapshot of ${snapshot.participants.length} participant(s) at block ${snapshot.block} written to ${out}`);
}
