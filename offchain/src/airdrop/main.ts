import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { parseArgs } from "node:util";
import { formatEther } from "viem";
import { createContext, log, repoRoot } from "../lib/context.js";
import { buildAirdrop } from "./build.js";

/**
 * Builds the airdrop Merkle tree from a test season and writes it, with every recipient's proof, to
 * `airdrop/<network>.json`. Needs RPC_URL. Usage: npm run airdrop -- --network base-sepolia --seasons 0
 */
const { values } = parseArgs({
  options: {
    network: { type: "string", default: "base-sepolia" },
    seasons: { type: "string", default: "0" },
    out: { type: "string" },
  },
});

const rpcUrl = process.env.RPC_URL;
if (!rpcUrl) {
  console.error("RPC_URL must be set");
  process.exit(1);
}

const ctx = await createContext({ network: values.network!, rpcUrl });
const seasons = values.seasons!.split(",").map(Number);
const tree = await buildAirdrop(ctx, seasons);

const out = values.out ?? join(repoRoot, "airdrop", `${ctx.network}.json`);
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, `${JSON.stringify(tree, null, 2)}\n`);

log(`seasons ${seasons.join(", ")}: ${tree.participants} participant(s), ${tree.recipients.length} eligible`);
log(`total ${formatEther(BigInt(tree.total))} TENAX of ${formatEther(BigInt(tree.budget))}`);
log(`root ${tree.root}`);
if (tree.pending.length > 0) {
  log(`warning: ${tree.pending.length} participant(s) have unsettled commitments; settle them and rebuild`);
}
log(`written to ${out}`);
