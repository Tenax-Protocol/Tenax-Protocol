import { parseArgs } from "node:util";
import type { Hex } from "viem";
import { createContext, log } from "../lib/context.js";
import { Keeper } from "./keeper.js";

/**
 * Keeper entry point. Runs one pass over every task and exits, which suits a scheduled job; `--loop <seconds>`
 * keeps running passes. Needs RPC_URL and KEEPER_PRIVATE_KEY in the environment.
 */
const { values } = parseArgs({
  options: {
    network: { type: "string", default: "base-sepolia" },
    loop: { type: "string" },
  },
});

const rpcUrl = process.env.RPC_URL;
const privateKey = process.env.KEEPER_PRIVATE_KEY as Hex | undefined;
if (!rpcUrl || !privateKey) {
  console.error("RPC_URL and KEEPER_PRIVATE_KEY must be set");
  process.exit(1);
}

const ctx = await createContext({ network: values.network!, rpcUrl, privateKey });
const keeper = new Keeper(ctx);
log(`keeper ${ctx.account!.address} on ${ctx.network}`);

const interval = values.loop ? Number(values.loop) * 1000 : 0;
do {
  const sent = await keeper.pass();
  log(`pass done: ${sent} task(s) executed`);
  if (interval) await new Promise((resolve) => setTimeout(resolve, interval));
} while (interval);
