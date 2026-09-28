import { forecastRegistryAbi, launchFeeHookAbi, seasonRewardsAbi, votingEscrowAbi } from "@abi";
import { useQuery } from "@tanstack/react-query";
import { type Address, erc20Abi } from "viem";
import { publicClient } from "./lib/client.js";
import { ASSETS, contracts, network } from "./lib/config.js";
import { currentRound, roundSchedule } from "./lib/forecast.js";

const REFRESH = 15_000;

export enum RoundStatus {
  None = 0,
  Open = 1,
  Resolved = 2,
  Voided = 3,
}

/** The registry's windows, each asset's state and the rounds around now, for every asset. */
export function useProtocol() {
  return useQuery({
    queryKey: ["protocol"],
    refetchInterval: REFRESH,
    queryFn: async () => {
      const now = Math.floor(Date.now() / 1000);
      const genesis = network.deployment.genesis;
      const round = currentRound(genesis, now) ?? 0n;
      const [submissionWindow, revealWindow, launchFee] = await Promise.all([
        publicClient.readContract({
          address: contracts.registry,
          abi: forecastRegistryAbi,
          functionName: "submissionWindow",
        }),
        publicClient.readContract({
          address: contracts.registry,
          abi: forecastRegistryAbi,
          functionName: "revealWindow",
        }),
        publicClient.readContract({ address: contracts.hook, abi: launchFeeHookAbi, functionName: "currentFee" }),
      ]);
      const assets = await Promise.all(
        ASSETS.map(async (asset) => {
          const [state, info] = await Promise.all([
            publicClient.readContract({
              address: contracts.registry,
              abi: forecastRegistryAbi,
              functionName: "assetState",
              args: [asset.id],
            }),
            publicClient.readContract({
              address: contracts.registry,
              abi: forecastRegistryAbi,
              functionName: "roundInfo",
              args: [asset.id, round],
            }),
          ]);
          return { ...asset, state, current: info };
        }),
      );
      return {
        genesis,
        round,
        started: now >= genesis,
        submissionWindow: Number(submissionWindow),
        revealWindow: Number(revealWindow),
        launchFee: Number(launchFee),
        assets,
        schedule: (r: bigint) => roundSchedule(genesis, r, Number(submissionWindow), Number(revealWindow)),
      };
    },
  });
}

export type Protocol = NonNullable<ReturnType<typeof useProtocol>["data"]>;

/** Balances and lock of `account`. */
export function usePosition(account?: Address) {
  return useQuery({
    queryKey: ["position", account],
    enabled: Boolean(account),
    refetchInterval: REFRESH,
    queryFn: async () => {
      const a = account!;
      const [eth, tenax, allowance, locked, ve] = await Promise.all([
        publicClient.getBalance({ address: a }),
        publicClient.readContract({ address: contracts.token, abi: erc20Abi, functionName: "balanceOf", args: [a] }),
        publicClient.readContract({
          address: contracts.token,
          abi: erc20Abi,
          functionName: "allowance",
          args: [a, contracts.escrow],
        }),
        publicClient.readContract({
          address: contracts.escrow,
          abi: votingEscrowAbi,
          functionName: "locked",
          args: [a],
        }),
        publicClient.readContract({
          address: contracts.escrow,
          abi: votingEscrowAbi,
          functionName: "balanceOf",
          args: [a],
        }),
      ]);
      const [amount, granted, end] = locked;
      return { eth, tenax, allowance, lock: { amount, granted, end: Number(end) }, ve };
    },
  });
}

export type Position = NonNullable<ReturnType<typeof usePosition>["data"]>;

/** Commitments of `account` in the last `depth` rounds of every asset, with each round's data. */
export function useCommitments(account: Address | undefined, round: bigint | undefined, depth = 4) {
  return useQuery({
    queryKey: ["commitments", account, round?.toString()],
    enabled: Boolean(account) && round !== undefined,
    refetchInterval: REFRESH,
    queryFn: async () => {
      const rounds: bigint[] = [];
      for (let r = round!; r >= 0n && rounds.length < depth; r--) rounds.push(r);
      const entries = await Promise.all(
        ASSETS.flatMap((asset) =>
          rounds.map(async (r) => {
            const [commitment, info] = await Promise.all([
              publicClient.readContract({
                address: contracts.registry,
                abi: forecastRegistryAbi,
                functionName: "commitmentOf",
                args: [asset.id, r, account!],
              }),
              publicClient.readContract({
                address: contracts.registry,
                abi: forecastRegistryAbi,
                functionName: "roundInfo",
                args: [asset.id, r],
              }),
            ]);
            return { asset, round: r, commitment, info };
          }),
        ),
      );
      return entries.filter((e) => e.commitment.hash !== `0x${"0".repeat(64)}`);
    },
  });
}

/** The latest `count` rounds of every asset, newest first. */
export function useRounds(round: bigint | undefined, count = 10) {
  return useQuery({
    queryKey: ["rounds", round?.toString(), count],
    enabled: round !== undefined,
    refetchInterval: 60_000,
    queryFn: async () => {
      const result = await Promise.all(
        ASSETS.map(async (asset) => {
          const rounds: bigint[] = [];
          for (let r = round!; r >= 0n && rounds.length < count; r--) rounds.push(r);
          const infos = await Promise.all(
            rounds.map((r) =>
              publicClient.readContract({
                address: contracts.registry,
                abi: forecastRegistryAbi,
                functionName: "roundInfo",
                args: [asset.id, r],
              }),
            ),
          );
          return { asset, rounds: rounds.map((r, i) => ({ round: r, info: infos[i]! })) };
        }),
      );
      return result;
    },
  });
}

/** Season rewards state for `account` in every season up to the current one. */
export function useSeasons(account?: Address) {
  return useQuery({
    queryKey: ["seasons", account],
    refetchInterval: 60_000,
    queryFn: async () => {
      const [current, nextToClose, period] = await Promise.all([
        publicClient.readContract({
          address: contracts.seasonRewards,
          abi: seasonRewardsAbi,
          functionName: "currentSeason",
        }),
        publicClient.readContract({
          address: contracts.seasonRewards,
          abi: seasonRewardsAbi,
          functionName: "nextSeasonToClose",
        }),
        publicClient.readContract({
          address: contracts.seasonRewards,
          abi: seasonRewardsAbi,
          functionName: "REGISTRATION_PERIOD",
        }),
      ]);
      const seasons = await Promise.all(
        Array.from({ length: Number(current) + 1 }, (_, i) => BigInt(i)).map(async (season) => {
          const [info, opensAt] = await Promise.all([
            publicClient.readContract({
              address: contracts.seasonRewards,
              abi: seasonRewardsAbi,
              functionName: "seasonInfo",
              args: [season],
            }),
            publicClient.readContract({
              address: contracts.seasonRewards,
              abi: seasonRewardsAbi,
              functionName: "registrationStart",
              args: [season],
            }),
          ]);
          const mine = account
            ? await Promise.all([
                publicClient.readContract({
                  address: contracts.seasonRewards,
                  abi: seasonRewardsAbi,
                  functionName: "registrationOf",
                  args: [season, account],
                }),
                publicClient.readContract({
                  address: contracts.seasonRewards,
                  abi: seasonRewardsAbi,
                  functionName: "claimable",
                  args: [season, account],
                }),
                publicClient.readContract({
                  address: contracts.registry,
                  abi: forecastRegistryAbi,
                  functionName: "isEligible",
                  args: [account, season],
                }),
              ])
            : undefined;
          return {
            season,
            info,
            registrationStart: Number(opensAt),
            registrationEnd: Number(opensAt + period),
            registration: mine?.[0],
            claimable: mine?.[1],
            eligible: mine?.[2] ?? false,
          };
        }),
      );
      return { current, nextToClose, seasons: seasons.reverse() };
    },
  });
}
