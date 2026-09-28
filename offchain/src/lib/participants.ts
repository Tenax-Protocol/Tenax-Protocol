import { type Address, parseAbiItem } from "viem";
import type { Context } from "./context.js";

const committedEvent = parseAbiItem(
  "event Committed(uint256 indexed asset, uint256 indexed round, address indexed participant, uint256 weight)",
);

/** Blocks per log query, below the range limits of public RPC endpoints. */
const LOG_CHUNK = 9_000n;

/** Every account that ever committed a forecast, from the registry's events since deployment. */
export async function participants(ctx: Context): Promise<Address[]> {
  const latest = await ctx.publicClient.getBlockNumber();
  const seen = new Set<Address>();
  for (let from = ctx.deployment.deployBlock; from <= latest; from += LOG_CHUNK) {
    const to = from + LOG_CHUNK - 1n < latest ? from + LOG_CHUNK - 1n : latest;
    const logs = await ctx.publicClient.getLogs({
      address: ctx.deployment.contracts.registry,
      event: committedEvent,
      fromBlock: from,
      toBlock: to,
    });
    for (const entry of logs) if (entry.args.participant) seen.add(entry.args.participant);
  }
  return [...seen].sort((a, b) => (a.toLowerCase() < b.toLowerCase() ? -1 : 1));
}
