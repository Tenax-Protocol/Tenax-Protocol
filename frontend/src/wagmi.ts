import { createConfig, http } from "wagmi";
import { coinbaseWallet } from "wagmi/connectors/coinbaseWallet";
import { injected } from "wagmi/connectors/injected";
import { network } from "./lib/config.js";

/** Browser extension wallets (MetaMask and others) and Coinbase Wallet, on the network the dApp targets. */
export const wagmiConfig = createConfig({
  chains: [network.chain],
  connectors: [injected(), coinbaseWallet({ appName: "Tenax Protocol" })],
  transports: { [network.chain.id]: http(network.rpcUrl) },
});

declare module "wagmi" {
  interface Register {
    config: typeof wagmiConfig;
  }
}
