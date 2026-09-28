import {
  type Abi,
  type Address,
  BaseError,
  ContractFunctionRevertedError,
  encodeFunctionData,
  erc20Abi,
  type Hex,
} from "viem";
import {
  forecastRegistryAbi,
  launchFeeHookAbi,
  liquidityVaultAbi,
  oracleAdapterAbi,
  revenueRouterAbi,
  seasonRewardsAbi,
  treasuryAbi,
} from "../abi/index.js";
import { roundHint } from "../lib/chainlink.js";
import { type Context, log } from "../lib/context.js";
import { participants } from "../lib/participants.js";

const DAY = 86_400n;
const ROUNDS_PER_PASS = 5;
const FINALIZE_LOOKBACK = 10n;

enum RoundStatus {
  None = 0,
  Open = 1,
  Resolved = 2,
  Voided = 3,
}

/** Every error the treasury's `execute` can bubble up, so reverts decode into names. */
const errorsAbi = [
  ...treasuryAbi,
  ...forecastRegistryAbi,
  ...oracleAdapterAbi,
  ...seasonRewardsAbi,
  ...liquidityVaultAbi,
  ...revenueRouterAbi,
  ...launchFeeHookAbi,
].filter((item) => item.type === "error") as Abi;

/**
 * Runs every keeper task once. Each task goes through `Treasury.execute`, which pays for it; every call is
 * simulated first, and a simulated revert only means the task is not due, so it is logged and skipped.
 */
export class Keeper {
  private readonly c: Context["deployment"]["contracts"];
  private taskIds?: Map<Hex, bigint>;
  private participantsCache?: Address[];

  constructor(private readonly ctx: Context) {
    this.c = ctx.deployment.contracts;
  }

  async pass(): Promise<number> {
    const block = await this.ctx.publicClient.getBlock();
    const now = block.timestamp;
    let sent = 0;
    sent += await this.resolveRounds(now);
    sent += await this.finalizeRounds(now);
    sent += await this.seasons(now);
    sent += await this.collectFees(now);
    sent += await this.buyback(now);
    sent += await this.distribute();
    this.participantsCache = undefined;
    return sent;
  }

  // --- forecasting -------------------------------------------------------------

  private async resolveRounds(now: bigint): Promise<number> {
    const assets = await this.read(this.c.registry, forecastRegistryAbi, "assetCount");
    let sent = 0;
    for (let asset = 0n; asset < assets; asset++) {
      for (let i = 0; i < ROUNDS_PER_PASS; i++) {
        const state = await this.read(this.c.registry, forecastRegistryAbi, "assetState", [asset]);
        const round = state.nextRoundToResolve;
        const times = await this.roundTimes(asset, round);
        if (now < times.resolveTime) break;

        const hints = await this.priceHints(asset, times.commitEnd, times.resolveTime);
        let done = false;
        if (hints) {
          const data = encodeFunctionData({
            abi: forecastRegistryAbi,
            functionName: "resolveRound",
            args: [asset, round, hints],
          });
          done = await this.runTask(data, `resolve asset ${asset} round ${round}`);
        }
        if (!done && now >= times.revealEnd) {
          const data = encodeFunctionData({
            abi: forecastRegistryAbi,
            functionName: "voidExpiredRound",
            args: [asset, round],
          });
          done = await this.runTask(data, `void asset ${asset} round ${round}`);
        }
        if (!done) break;
        sent++;
      }
    }
    return sent;
  }

  private async finalizeRounds(now: bigint): Promise<number> {
    const assets = await this.read(this.c.registry, forecastRegistryAbi, "assetCount");
    let sent = 0;
    for (let asset = 0n; asset < assets; asset++) {
      const { nextRoundToResolve: next } = await this.read(this.c.registry, forecastRegistryAbi, "assetState", [asset]);
      const first = next > FINALIZE_LOOKBACK ? next - FINALIZE_LOOKBACK : 0n;
      for (let round = first; round < next; round++) {
        const info = await this.read(this.c.registry, forecastRegistryAbi, "roundInfo", [asset, round]);
        const closed = info.status === RoundStatus.Resolved || info.status === RoundStatus.Voided;
        if (info.finalized || !closed || now < info.revealEnd) continue;
        const data = encodeFunctionData({ abi: forecastRegistryAbi, functionName: "finalizeRound", args: [asset, round] });
        if (await this.runTask(data, `finalize asset ${asset} round ${round}`)) sent++;
      }
    }
    return sent;
  }

  /** Schedule of a round: stored once it opened, otherwise derived from the current windows. */
  private async roundTimes(asset: bigint, round: bigint) {
    const info = await this.read(this.c.registry, forecastRegistryAbi, "roundInfo", [asset, round]);
    if (info.status !== RoundStatus.None) {
      return { commitEnd: info.commitEnd, resolveTime: info.resolveTime, revealEnd: info.revealEnd };
    }
    const [submission, reveal] = await Promise.all([
      this.read(this.c.registry, forecastRegistryAbi, "submissionWindow"),
      this.read(this.c.registry, forecastRegistryAbi, "revealWindow"),
    ]);
    const commitEnd = this.ctx.deployment.genesis + round * DAY + submission;
    const resolveTime = commitEnd + DAY;
    return { commitEnd, resolveTime, revealEnd: resolveTime + reveal };
  }

  /** Chainlink rounds active at both checkpoints, or null when either cannot be proven. */
  private async priceHints(asset: bigint, commitEnd: bigint, resolveTime: bigint) {
    const client = this.ctx.publicClient;
    const [feed, sequencer] = await Promise.all([
      this.read(this.c.oracle, oracleAdapterAbi, "feed", [asset]),
      this.read(this.c.oracle, oracleAdapterAbi, "sequencerUptimeFeed"),
    ]);
    const [refPrice, refSequencer, closePrice, closeSequencer] = await Promise.all([
      roundHint(client, feed.aggregator, commitEnd, "updatedAt"),
      roundHint(client, sequencer, commitEnd, "startedAt"),
      roundHint(client, feed.aggregator, resolveTime, "updatedAt"),
      roundHint(client, sequencer, resolveTime, "startedAt"),
    ]);
    if (refPrice === null || refSequencer === null || closePrice === null || closeSequencer === null) return null;
    return {
      refPriceRound: refPrice,
      refSequencerRound: refSequencer,
      closePriceRound: closePrice,
      closeSequencerRound: closeSequencer,
    };
  }

  // --- seasons -----------------------------------------------------------------

  private async seasons(now: bigint): Promise<number> {
    const season = await this.read(this.c.seasonRewards, seasonRewardsAbi, "nextSeasonToClose");
    const [opensAt, period] = await Promise.all([
      this.read(this.c.seasonRewards, seasonRewardsAbi, "registrationStart", [season]),
      this.read(this.c.seasonRewards, seasonRewardsAbi, "REGISTRATION_PERIOD"),
    ]);
    if (now >= opensAt + period) {
      const data = encodeFunctionData({ abi: seasonRewardsAbi, functionName: "closeSeason", args: [season] });
      return (await this.runTask(data, `close season ${season}`)) ? 1 : 0;
    }
    if (now < opensAt) return 0;

    let sent = 0;
    for (const participant of await this.participants()) {
      const registration = await this.read(this.c.seasonRewards, seasonRewardsAbi, "registrationOf", [season, participant]);
      if (registration.contribution !== 0n) continue;
      const stats = await this.read(this.c.registry, forecastRegistryAbi, "seasonStats", [participant, season]);
      const pending = await this.read(this.c.registry, forecastRegistryAbi, "pendingCount", [participant]);
      if (stats.rounds === 0 && pending === 0n) continue;
      const data = encodeFunctionData({ abi: seasonRewardsAbi, functionName: "register", args: [participant, season] });
      if (await this.runTask(data, `register ${participant} for season ${season}`)) sent++;
    }
    return sent;
  }

  private async participants(): Promise<Address[]> {
    this.participantsCache ??= await participants(this.ctx);
    return this.participantsCache;
  }

  // --- liquidity and revenue ---------------------------------------------------

  private async collectFees(now: bigint): Promise<number> {
    const [tokenId, last] = await Promise.all([
      this.read(this.c.vault, liquidityVaultAbi, "tokenId"),
      this.read(this.c.vault, liquidityVaultAbi, "lastCollect"),
    ]);
    if (tokenId === 0n || (last !== 0n && now < last + DAY)) return 0;
    const data = encodeFunctionData({ abi: liquidityVaultAbi, functionName: "collectFees" });
    return (await this.runTask(data, "collect fees")) ? 1 : 0;
  }

  private async buyback(now: bigint): Promise<number> {
    const [last, reserve, balance] = await Promise.all([
      this.read(this.c.treasury, treasuryAbi, "lastBuyback"),
      this.read(this.c.treasury, treasuryAbi, "ethReserveTarget"),
      this.read(this.c.weth, erc20Abi, "balanceOf", [this.c.treasury]),
    ]);
    if ((last !== 0n && now < last + DAY) || balance <= reserve) return 0;
    const data = encodeFunctionData({ abi: treasuryAbi, functionName: "buyback" });
    return (await this.runTask(data, "buyback")) ? 1 : 0;
  }

  private async distribute(): Promise<number> {
    const balance = await this.read(this.c.weth, erc20Abi, "balanceOf", [this.c.router]);
    if (balance === 0n) return 0;
    const data = encodeFunctionData({ abi: revenueRouterAbi, functionName: "distribute" });
    return (await this.runTask(data, "distribute revenue")) ? 1 : 0;
  }

  // --- execution ---------------------------------------------------------------

  /** Simulates and sends `Treasury.execute` for the task matching `data`'s selector. */
  private async runTask(data: Hex, label: string): Promise<boolean> {
    const { publicClient, walletClient, account } = this.ctx;
    if (!walletClient || !account) throw new Error("the keeper needs KEEPER_PRIVATE_KEY");
    const taskId = (await this.taskIdsBySelector()).get(data.slice(0, 10) as Hex);
    if (taskId === undefined) throw new Error(`no treasury task for ${label}`);
    try {
      const call = {
        address: this.c.treasury,
        abi: [...treasuryAbi, ...errorsAbi],
        functionName: "execute",
        args: [taskId, data],
        account,
      } as const;
      await publicClient.simulateContract(call);
      // The treasury refunds `tx.gasprice`, and paying the refund in locked TENAX costs far more gas than skipping
      // it. A node estimates gas at a zero gas price, where the refund is zero and skipped, so the estimate must
      // use the real fees, with a margin, or the transaction runs out of gas.
      const { maxFeePerGas, maxPriorityFeePerGas } = await publicClient.estimateFeesPerGas();
      const gas = await publicClient.estimateContractGas({ ...call, maxFeePerGas, maxPriorityFeePerGas });
      const hash = await walletClient.writeContract({
        ...call,
        chain: walletClient.chain,
        maxFeePerGas,
        maxPriorityFeePerGas,
        gas: (gas * 12n) / 10n + 50_000n,
      });
      const receipt = await publicClient.waitForTransactionReceipt({ hash });
      log(`${label}: ${receipt.status} in ${hash}`);
      return receipt.status === "success";
    } catch (error) {
      log(`${label}: skipped (${reason(error)})`);
      return false;
    }
  }

  private async taskIdsBySelector(): Promise<Map<Hex, bigint>> {
    if (this.taskIds) return this.taskIds;
    const count = await this.read(this.c.treasury, treasuryAbi, "taskCount");
    const ids = new Map<Hex, bigint>();
    for (let id = 0n; id < count; id++) {
      const task = await this.read(this.c.treasury, treasuryAbi, "task", [id]);
      ids.set(task.selector, id);
    }
    this.taskIds = ids;
    return ids;
  }

  /** Loosely typed read: the keeper only reads a handful of well-known views. */
  private read<const abi extends Abi, fn extends string>(address: Address, abi: abi, functionName: fn, args?: unknown[]): Promise<any> {
    return this.ctx.publicClient.readContract({ address, abi, functionName, args } as never);
  }
}

/** Short reason for a simulated revert: the decoded custom error when there is one. */
function reason(error: unknown): string {
  if (error instanceof BaseError) {
    const revert = error.walk((e) => e instanceof ContractFunctionRevertedError);
    if (revert instanceof ContractFunctionRevertedError) {
      return revert.data?.errorName ?? revert.reason ?? revert.shortMessage;
    }
    return error.shortMessage;
  }
  return String(error);
}
