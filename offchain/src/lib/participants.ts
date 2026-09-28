import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { type Address, parseAbiItem } from "viem";
import { type Context, repoRoot } from "./context.js";

const committedEvent = parseAbiItem(
  "event Committed(uint256 indexed asset, uint256 indexed round, address indexed participant, uint256 weight)",
);

/**
 * Blocks per log query. The public Base endpoints accept at most 1,000; a dedicated RPC can take more
 * (LOG_CHUNK in the environment).
 */
const LOG_CHUNK = BigInt(process.env.LOG_CHUNK ?? 1_000);

interface Cache {
  registry: Address;
  deployBlock: string;
  nextBlock: string;
  accounts: Address[];
}

function cachePath(ctx: Context): string {
  return join(repoRoot, "offchain", ".cache", `${ctx.network}-participants.json`);
}

/**
 * Every account that ever committed a forecast, from the registry's events since deployment. Scans incrementally:
 * the accounts found and the next block to scan are cached in `offchain/.cache`, so repeated runs (the keeper every
 * 10 minutes) only query the blocks mined since the last one. A cache from another deployment, or ahead of the chain
 * (a local fork started again), is discarded.
 */
export async function participants(ctx: Context): Promise<Address[]> {
  const path = cachePath(ctx);
  const registry = ctx.deployment.contracts.registry;
  const deployBlock = ctx.deployment.deployBlock.toString();
  const latest = await ctx.publicClient.getBlockNumber();
  let cache: Cache = { registry, deployBlock, nextBlock: deployBlock, accounts: [] };
  if (existsSync(path)) {
    const saved = JSON.parse(readFileSync(path, "utf8")) as Cache;
    const sameDeployment = saved.registry?.toLowerCase() === registry.toLowerCase() && saved.deployBlock === deployBlock;
    if (sameDeployment && BigInt(saved.nextBlock) <= latest + 1n) cache = saved;
  }

  const seen = new Set<Address>(cache.accounts);
  for (let from = BigInt(cache.nextBlock); from <= latest; from += LOG_CHUNK) {
    const to = from + LOG_CHUNK - 1n < latest ? from + LOG_CHUNK - 1n : latest;
    const logs = await ctx.publicClient.getLogs({ address: registry, event: committedEvent, fromBlock: from, toBlock: to });
    for (const entry of logs) if (entry.args.participant) seen.add(entry.args.participant);
  }

  const accounts = [...seen].sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1));
  const saved: Cache = { registry, deployBlock, nextBlock: (latest + 1n).toString(), accounts };
  mkdirSync(dirname(path), { recursive: true });
  writeFileSync(path, `${JSON.stringify(saved, null, 2)}\n`);
  return accounts;
}
