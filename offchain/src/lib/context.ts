import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import {
  type Account,
  type Address,
  createPublicClient,
  createWalletClient,
  defineChain,
  type Hex,
  http,
  type PublicClient,
  type WalletClient,
} from "viem";
import { privateKeyToAccount } from "viem/accounts";

/** Addresses and launch parameters written by contracts/script/Deploy.s.sol. */
export interface Deployment {
  chainId: number;
  deployBlock: bigint;
  genesis: bigint;
  positionId: bigint;
  poolKey: { currency0: Address; currency1: Address; fee: number; tickSpacing: number; hooks: Address };
  contracts: Record<
    | "token"
    | "escrow"
    | "oracle"
    | "registry"
    | "schedule"
    | "treasury"
    | "seasonRewards"
    | "feeDistributor"
    | "router"
    | "vault"
    | "airdrop"
    | "creatorVesting"
    | "timelock"
    | "governor"
    | "launcher"
    | "hook"
    | "poolManager"
    | "positionManager"
    | "weth",
    Address
  >;
}

export const repoRoot = join(dirname(fileURLToPath(import.meta.url)), "..", "..", "..");

export function deploymentPath(network: string): string {
  return join(repoRoot, "deployments", `${network}.json`);
}

export function loadDeployment(network: string): Deployment {
  const raw = JSON.parse(readFileSync(deploymentPath(network), "utf8"));
  return {
    ...raw,
    deployBlock: BigInt(raw.deployBlock),
    genesis: BigInt(raw.genesis),
    positionId: BigInt(raw.positionId),
  };
}

export interface Context {
  network: string;
  deployment: Deployment;
  publicClient: PublicClient;
  walletClient?: WalletClient;
  account?: Account;
}

export async function createContext(options: { network: string; rpcUrl: string; privateKey?: Hex }): Promise<Context> {
  const deployment = loadDeployment(options.network);
  const chain = defineChain({
    id: deployment.chainId,
    name: options.network,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [options.rpcUrl] } },
  });
  const transport = http(options.rpcUrl);
  const publicClient = createPublicClient({ chain, transport }) as PublicClient;
  const chainId = await publicClient.getChainId();
  if (chainId !== deployment.chainId) {
    throw new Error(`RPC chain ${chainId} does not match deployment chain ${deployment.chainId}`);
  }
  if (!options.privateKey) return { network: options.network, deployment, publicClient };
  const account = privateKeyToAccount(options.privateKey);
  const walletClient = createWalletClient({ account, chain, transport });
  return { network: options.network, deployment, publicClient, walletClient, account };
}

export function log(message: string): void {
  console.log(`[${new Date().toISOString()}] ${message}`);
}
