import { type ChildProcess, spawn, spawnSync } from "node:child_process";
import { rmSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  type Address,
  createPublicClient,
  createTestClient,
  createWalletClient,
  defineChain,
  formatEther,
  type Hex,
  http,
  keccak256,
  parseEther,
  toHex,
  zeroAddress,
} from "viem";
import { mnemonicToAccount, type HDAccount } from "viem/accounts";
import {
  forecastRegistryAbi,
  mockAggregatorAbi,
  mockAggregatorBytecode,
  seasonRewardsAbi,
  tenaxTokenAbi,
  v4SwapperAbi,
  v4SwapperBytecode,
  votingEscrowAbi,
} from "../abi/index.js";
import { buildAirdrop } from "../airdrop/build.js";
import { Keeper } from "../keeper/keeper.js";
import { createContext, type Deployment, deploymentPath, loadDeployment, log, repoRoot } from "../lib/context.js";

/**
 * Rehearses a full test season on a local fork of Base Sepolia, against the real Uniswap v4 deployment there:
 * deploys the protocol with the deployment script, has six participants buy TENAX in the pool and lock it, plays
 * the 30 daily rounds of season 0 on both assets with prices pushed to mock feeds, lets the real keeper resolve,
 * finalize, register, close and collect, has participants claim, and builds the airdrop tree from the season.
 * Fails loudly if anything does not end as the design says it should.
 *
 * Needs Foundry (anvil, forge) and network access to a Base Sepolia RPC (SEPOLIA_RPC_URL, public by default).
 */

const PORT = 8549;
const RPC = `http://127.0.0.1:${PORT}`;
const CHAIN_ID = 31_337;
const NETWORK = String(CHAIN_ID);
const DAY = 86_400n;
const SEASON_ROUNDS = 30n;
const SUBMISSION = 30n * 60n;
const MNEMONIC = "test test test test test test test test test test test junk";
const FOUNDRY_BIN = process.env.FOUNDRY_BIN ?? join(homedir(), ".foundry", "bin");
const SEPOLIA_RPC = process.env.SEPOLIA_RPC_URL ?? "https://sepolia.base.org";

type Strategy = "skilled" | "baseRate" | "random";

interface Participant {
  name: string;
  strategy: Strategy;
  account: HDAccount;
  secrets: Map<string, { forecast: bigint; salt: Hex }>;
}

const chain = defineChain({
  id: CHAIN_ID,
  name: "rehearsal",
  nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
  rpcUrls: { default: { http: [RPC] } },
});
const publicClient = createPublicClient({ chain, transport: http(RPC) });
const testClient = createTestClient({ chain, mode: "anvil", transport: http(RPC) });
const wallet = (account: HDAccount) => createWalletClient({ account, chain, transport: http(RPC) });
const accountAt = (index: number) => mnemonicToAccount(MNEMONIC, { addressIndex: index });

// --- deterministic market ------------------------------------------------------

/** Pseudo-random but reproducible: whether an asset's price moves more than its threshold in a round. */
function bigMove(asset: bigint, round: bigint): boolean {
  return BigInt(keccak256(toHex(`move-${asset}-${round}`))) % 100n < 35n;
}

/** Price at checkpoint `day` (8 decimals): moves 8% on big days and 0.2% otherwise, alternating direction. */
function priceAt(asset: bigint, day: bigint): bigint {
  let price = asset === 0n ? 60_000_00000000n : 3_000_00000000n;
  for (let d = 0n; d < day; d++) {
    const up = d % 2n === 0n;
    const move = bigMove(asset, d) ? 800n : 20n; // basis points
    price = up ? (price * (10_000n + move)) / 10_000n : (price * (10_000n - move)) / 10_000n;
  }
  return price;
}

function forecastFor(strategy: Strategy, asset: bigint, round: bigint): bigint {
  if (strategy === "skilled") return bigMove(asset, round) ? 9_000n : 1_000n;
  if (strategy === "baseRate") return 3_600n;
  return BigInt(keccak256(toHex(`random-${asset}-${round}`))) % 10_001n;
}

// --- chain helpers -------------------------------------------------------------

async function setTime(timestamp: bigint): Promise<void> {
  await testClient.setNextBlockTimestamp({ timestamp });
  await testClient.mine({ blocks: 1 });
}

/** Sends a contract call and waits for it; the rehearsal only builds requests from generated ABIs. */
async function send(account: HDAccount, request: object) {
  // Simulating first turns a revert into a decoded error instead of a bare failed receipt.
  await publicClient.simulateContract({ ...request, account } as never);
  const hash = await wallet(account).writeContract(request as never);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") {
    const trace = await publicClient.request({
      method: "debug_traceTransaction" as never,
      params: [hash, { tracer: "callTracer" }] as never,
    });
    throw new Error(`transaction ${hash} reverted (gas ${receipt.gasUsed}):
${JSON.stringify(trace, null, 1).slice(0, 4000)}`);
  }
  return receipt;
}

interface CallFrame {
  from: Address;
  to?: Address;
  value?: Hex;
  calls?: CallFrame[];
}

/** Total native ETH sent from `from` to `to` anywhere in a transaction's call tree. */
async function nativeTransfers(hash: Hex, from: Address, to: Address): Promise<bigint> {
  const root = (await publicClient.request({
    method: "debug_traceTransaction" as never,
    params: [hash, { tracer: "callTracer" }] as never,
  })) as CallFrame;
  let total = 0n;
  const visit = (frame: CallFrame) => {
    if (frame.from.toLowerCase() === from.toLowerCase() && frame.to?.toLowerCase() === to.toLowerCase()) {
      total += BigInt(frame.value ?? "0x0");
    }
    for (const call of frame.calls ?? []) visit(call);
  };
  visit(root);
  return total;
}

function check(condition: boolean, message: string): void {
  if (!condition) throw new Error(`rehearsal check failed: ${message}`);
  log(`ok: ${message}`);
}

// --- steps ---------------------------------------------------------------------

function startAnvil(): ChildProcess {
  const anvil = spawn(
    join(FOUNDRY_BIN, "anvil"),
    ["--fork-url", SEPOLIA_RPC, "--chain-id", String(CHAIN_ID), "--port", String(PORT), "--silent"],
    { stdio: "ignore" },
  );
  return anvil;
}

async function waitForAnvil(): Promise<void> {
  for (let i = 0; i < 60; i++) {
    try {
      await publicClient.getChainId();
      return;
    } catch {
      await new Promise((resolve) => setTimeout(resolve, 1000));
    }
  }
  throw new Error("anvil did not start");
}

async function deployFeeds(deployer: HDAccount): Promise<[Address, Address]> {
  const feeds: Address[] = [];
  for (let i = 0; i < 2; i++) {
    const hash = await wallet(deployer).deployContract({
      abi: mockAggregatorAbi,
      bytecode: mockAggregatorBytecode,
      args: [8],
    });
    const receipt = await publicClient.waitForTransactionReceipt({ hash });
    feeds.push(receipt.contractAddress!);
  }
  return [feeds[0]!, feeds[1]!];
}

function deployProtocol(deployer: HDAccount, feeds: [Address, Address], genesis: bigint): Deployment {
  rmSync(deploymentPath(NETWORK), { force: true });
  const env = {
    ...process.env,
    SAFE: accountAt(9).address,
    CREATOR: accountAt(8).address,
    GENESIS: genesis.toString(),
    INITIAL_THRESHOLDS: "20000000000000000,28000000000000000",
    INITIAL_BASE_RATES: "360000000000000000,360000000000000000",
    AIRDROP_ROOT: `0x${"11".repeat(32)}`,
    POOL_MANAGER: "0x05E73354cFDd6745C338b50BcFDfA3Aa6fA03408",
    POSITION_MANAGER: "0x4B2C77d209D3405F41a037Ec6c77F7F5b8e2ca80",
    BTC_USD_FEED: feeds[0],
    ETH_USD_FEED: feeds[1],
    SEQUENCER_FEED: zeroAddress,
    STALENESS: "3960",
  };
  const privateKey = toHex(deployer.getHdKey().privateKey!);
  const result = spawnSync(
    join(FOUNDRY_BIN, "forge"),
    ["script", "script/Deploy.s.sol", "--rpc-url", RPC, "--broadcast", "--private-key", privateKey],
    { cwd: join(repoRoot, "contracts"), env, encoding: "utf8" },
  );
  if (result.status !== 0) throw new Error(`deployment failed:\n${result.stdout}\n${result.stderr}`);
  return loadDeployment(NETWORK);
}

async function onboard(d: Deployment, participants: Participant[], swapper: Address): Promise<void> {
  const poolKey = { ...d.poolKey, fee: d.poolKey.fee, tickSpacing: d.poolKey.tickSpacing };
  const now = (await publicClient.getBlock()).timestamp;
  for (const p of participants) {
    await send(p.account, {
      address: swapper,
      abi: v4SwapperAbi,
      functionName: "buy",
      args: [poolKey],
      value: parseEther("0.02"),
    });
    const balance = await publicClient.readContract({
      address: d.contracts.token,
      abi: tenaxTokenAbi,
      functionName: "balanceOf",
      args: [p.account.address],
    });
    await send(p.account, {
      address: d.contracts.token,
      abi: tenaxTokenAbi,
      functionName: "approve",
      args: [d.contracts.escrow, balance],
    });
    await send(p.account, {
      address: d.contracts.escrow,
      abi: votingEscrowAbi,
      functionName: "createLock",
      args: [balance, now + 104n * 7n * DAY],
    });
  }
}

async function commitAll(d: Deployment, participants: Participant[], round: bigint): Promise<void> {
  for (const p of participants) {
    for (const asset of [0n, 1n]) {
      const forecast = forecastFor(p.strategy, asset, round);
      const salt = keccak256(toHex(`${p.name}-${asset}-${round}`));
      const hash = await publicClient.readContract({
        address: d.contracts.registry,
        abi: forecastRegistryAbi,
        functionName: "commitmentHash",
        args: [asset, round, p.account.address, forecast, salt],
      });
      await send(p.account, {
        address: d.contracts.registry,
        abi: forecastRegistryAbi,
        functionName: "commit",
        args: [asset, round, hash],
      });
      p.secrets.set(`${asset}-${round}`, { forecast, salt });
    }
  }
}

async function revealAll(d: Deployment, participants: Participant[], round: bigint): Promise<void> {
  for (const p of participants) {
    for (const asset of [0n, 1n]) {
      const secret = p.secrets.get(`${asset}-${round}`);
      if (!secret) continue;
      await send(p.account, {
        address: d.contracts.registry,
        abi: forecastRegistryAbi,
        functionName: "reveal",
        args: [asset, round, secret.forecast, secret.salt],
      });
    }
  }
}

async function publishPrices(d: Deployment, deployer: HDAccount, feeds: [Address, Address], day: bigint): Promise<void> {
  const checkpoint = d.genesis + day * DAY + SUBMISSION;
  for (const asset of [0n, 1n]) {
    await send(deployer, {
      address: feeds[Number(asset)]!,
      abi: mockAggregatorAbi,
      functionName: "push",
      args: [priceAt(asset, day), checkpoint, checkpoint],
    });
  }
}

/** Runs keeper passes until one of them has nothing left to do. */
async function keep(keeper: Keeper): Promise<number> {
  let total = 0;
  for (let i = 0; i < 20; i++) {
    const sent = await keeper.pass();
    total += sent;
    if (sent === 0) break;
  }
  return total;
}

// --- main ----------------------------------------------------------------------

async function main(): Promise<void> {
  const anvil = startAnvil();
  try {
    await waitForAnvil();
    log(`anvil forking ${SEPOLIA_RPC} on ${RPC}`);
    const deployer = accountAt(0);
    const keeperAccount = accountAt(1);
    const strategies: Strategy[] = ["skilled", "skilled", "baseRate", "baseRate", "random", "random"];
    const participants: Participant[] = strategies.map((strategy, i) => ({
      name: `${strategy}-${i}`,
      strategy,
      account: accountAt(i + 2),
      secrets: new Map(),
    }));

    const start = (await publicClient.getBlock()).timestamp;
    const genesis = (start / DAY + 2n) * DAY;
    const feeds = await deployFeeds(deployer);
    const d = deployProtocol(deployer, feeds, genesis);
    log(`protocol deployed, genesis ${new Date(Number(genesis) * 1000).toISOString()}`);

    const swapHash = await wallet(deployer).deployContract({
      abi: v4SwapperAbi,
      bytecode: v4SwapperBytecode,
      args: [d.contracts.poolManager],
    });
    const swapper = (await publicClient.waitForTransactionReceipt({ hash: swapHash })).contractAddress!;
    await onboard(d, participants, swapper);
    log(`${participants.length} participants bought TENAX in the pool and locked it`);

    const ctx = await createContext({
      network: NETWORK,
      rpcUrl: RPC,
      privateKey: toHex(keeperAccount.getHdKey().privateKey!),
    });
    const keeper = new Keeper(ctx);

    // Day d: commit round d at its opening, then publish checkpoint d, which is round d's reference price and
    // round d-1's closing price, reveal round d-1 and let the keeper work.
    for (let day = 0n; day <= SEASON_ROUNDS; day++) {
      const open = genesis + day * DAY;
      if (day < SEASON_ROUNDS) {
        await setTime(open + 60n);
        await commitAll(d, participants, day);
      }
      await setTime(open + SUBMISSION);
      await publishPrices(d, deployer, feeds, day);
      if (day > 0n) await revealAll(d, participants, day - 1n);
      await keep(keeper);
      if (day % 10n === 0n) log(`day ${day} played`);
    }

    // Past every reveal window, then into season 0's registration period and past its end.
    const registration = await publicClient.readContract({
      address: d.contracts.seasonRewards,
      abi: seasonRewardsAbi,
      functionName: "registrationStart",
      args: [0n],
    });
    await setTime(registration + 60n);
    await keep(keeper);
    await setTime(registration + 7n * DAY + 60n);
    await keep(keeper);

    // --- checks ------------------------------------------------------------------
    for (const asset of [0n, 1n]) {
      for (let round = 0n; round < SEASON_ROUNDS; round++) {
        const info = await publicClient.readContract({
          address: d.contracts.registry,
          abi: forecastRegistryAbi,
          functionName: "roundInfo",
          args: [asset, round],
        });
        if (info.status !== 2 || !info.finalized) {
          throw new Error(`asset ${asset} round ${round}: status ${info.status}, finalized ${info.finalized}`);
        }
        if (info.outcome !== bigMove(asset, round)) throw new Error(`asset ${asset} round ${round}: wrong outcome`);
      }
    }
    log("ok: all 60 rounds of season 0 resolved with the expected outcomes and finalized");

    const season = await publicClient.readContract({
      address: d.contracts.seasonRewards,
      abi: seasonRewardsAbi,
      functionName: "seasonInfo",
      args: [0n],
    });
    check(season.closed, "season 0 closed by the keeper");
    const registered: string[] = [];
    for (const p of participants) {
      const r = await publicClient.readContract({
        address: d.contracts.seasonRewards,
        abi: seasonRewardsAbi,
        functionName: "registrationOf",
        args: [0n, p.account.address],
      });
      if (r.contribution > 0n) registered.push(p.strategy);
    }
    check(
      registered.length === 2 && registered.every((s) => s === "skilled"),
      `only the skilled forecasters registered (${registered.join(", ")})`,
    );

    check(season.ethBudget > 0n, `season 0 has an ETH budget from pool fees (${formatEther(season.ethBudget)} ETH)`);
    for (const p of participants.filter((q) => q.strategy === "skilled")) {
      const [tenax, eth] = await publicClient.readContract({
        address: d.contracts.seasonRewards,
        abi: seasonRewardsAbi,
        functionName: "claimable",
        args: [0n, p.account.address],
      });
      const [lockedBefore] = await publicClient.readContract({
        address: d.contracts.escrow,
        abi: votingEscrowAbi,
        functionName: "locked",
        args: [p.account.address],
      });
      const receipt = await send(p.account, {
        address: d.contracts.seasonRewards,
        abi: seasonRewardsAbi,
        functionName: "claimAsEth",
        args: [0n],
      });
      const [lockedAfter] = await publicClient.readContract({
        address: d.contracts.escrow,
        abi: votingEscrowAbi,
        functionName: "locked",
        args: [p.account.address],
      });
      // Anvil charges an OP Stack L1 data fee on this fork without reporting it in the receipt, so the native ETH
      // payment is read from the call trace instead of from balance differences.
      const paid = await nativeTransfers(receipt.transactionHash, d.contracts.seasonRewards, p.account.address);
      log(`${p.name} claimed ${formatEther(tenax)} TENAX (locked) and ${formatEther(eth)} ETH`);
      check(lockedAfter - lockedBefore === tenax && tenax > 0n, `${p.name}'s TENAX reward is locked in the escrow`);
      check(paid === eth && eth > 0n, `${p.name} received exactly the claimable ETH as native ETH`);
    }

    const tree = await buildAirdrop(ctx, [0]);
    const eligible = tree.recipients.map((r) => r.account.toLowerCase());
    const skilled = participants.filter((p) => p.strategy === "skilled").map((p) => p.account.address.toLowerCase());
    check(
      eligible.length === skilled.length && skilled.every((a) => eligible.includes(a)),
      `the airdrop goes to the skilled forecasters only, root ${tree.root}`,
    );
    check(BigInt(tree.total) <= BigInt(tree.budget), "the airdrop never exceeds 10M TENAX");
    log("rehearsal complete");
  } finally {
    anvil.kill();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
