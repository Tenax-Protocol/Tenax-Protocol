import { createPublicClient, http } from "viem";
import { network } from "./config.js";

/** Read-only client for every view the dApp shows; writes go through the connected wallet. */
export const publicClient = createPublicClient({
  chain: network.chain,
  transport: http(network.rpcUrl, { batch: true }),
});
