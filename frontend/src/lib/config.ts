import type { Address } from "viem";
import { baseSepolia } from "viem/chains";
import baseSepoliaDeployment from "@deployments/base-sepolia.json";

/** Addresses and launch parameters written by contracts/script/Deploy.s.sol. */
export interface Deployment {
  chainId: number;
  deployBlock: number;
  genesis: number;
  positionId: number;
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

/** Uniswap v4 periphery used to buy TENAX: the Universal Router executes, the quoter prices. */
export interface Uniswap {
  universalRouter: Address;
  quoter: Address;
}

export interface Network {
  chain: typeof baseSepolia;
  rpcUrl: string;
  explorer: string;
  deployment: Deployment;
  uniswap: Uniswap;
  testnet: boolean;
}

export const network: Network = {
  chain: baseSepolia,
  rpcUrl: "https://sepolia.base.org",
  explorer: "https://sepolia.basescan.org",
  deployment: baseSepoliaDeployment as Deployment,
  uniswap: {
    universalRouter: "0x492E6456D9528771018DeB9E87ef7750EF184104",
    quoter: "0x4A6513c898fe1B2d0E78d3b0e0A4a151589B1cBa",
  },
  testnet: true,
};

export const contracts = network.deployment.contracts;

export const ASSETS = [
  { id: 0n, symbol: "BTC", name: "Bitcoin" },
  { id: 1n, symbol: "ETH", name: "Ether" },
] as const;

/** Protocol constants mirrored from the contracts. */
export const DAY = 86_400;
export const WEEK = 7 * DAY;
export const MAX_LOCK = 104 * WEEK;
export const MIN_VE = 5_000n * 10n ** 18n;
export const SEASON_LENGTH = 30 * DAY;
export const BPS = 10_000;

export const explorerAddress = (address: string) => `${network.explorer}/address/${address}`;
export const explorerTx = (hash: string) => `${network.explorer}/tx/${hash}`;
