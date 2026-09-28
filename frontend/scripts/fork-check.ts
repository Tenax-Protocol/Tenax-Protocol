import { type ChildProcess, spawn } from "node:child_process";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  createPublicClient,
  createTestClient,
  createWalletClient,
  erc20Abi,
  formatEther,
  http,
  parseEther,
} from "viem";
import { mnemonicToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { forecastRegistryAbi, votingEscrowAbi } from "@abi";
import { contracts, MAX_LOCK, MIN_VE, network } from "../src/lib/config.js";
import { amountForVe, roundDownToWeek, veBalance } from "../src/lib/escrow.js";
import {
  commitmentHash,
  deriveSalt,
  forecastKey,
  forecastKeyMessage,
  recoverForecast,
  roundSchedule,
} from "../src/lib/forecast.js";
import { encodeBuy, quoterAbi, universalRouterAbi, withSlippage } from "../src/lib/swap.js";

/**
 * Checks the dApp's transaction encodings against the live Base Sepolia deployment, on a local fork: quote and buy
 * TENAX through the Universal Router, lock enough of it to forecast, commit a forecast with a signature-derived
 * salt, recover the forecast from the commitment alone and reveal it. Needs anvil (Foundry).
 */

const PORT = 8555;
const RPC = `http://127.0.0.1:${PORT}`;
const chain = { ...baseSepolia, rpcUrls: { default: { http: [RPC] } } };
const publicClient = createPublicClient({ chain, transport: http(RPC) });
const testClient = createTestClient({ chain, mode: "anvil", transport: http(RPC) });
const account = mnemonicToAccount("test test test test test test test test test test test junk", { addressIndex: 3 });
const wallet = createWalletClient({ account, chain, transport: http(RPC) });
const d = network.deployment;

function check(condition: boolean, message: string): void {
  if (!condition) throw new Error(`check failed: ${message}`);
  console.log(`ok: ${message}`);
}

async function send(request: object) {
  await publicClient.simulateContract({ ...request, account } as never);
  const hash = await wallet.writeContract({ ...request, chain } as never);
  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`reverted: ${hash}`);
  return receipt;
}

async function main(): Promise<void> {
  const anvil: ChildProcess = spawn(
    join(process.env.FOUNDRY_BIN ?? join(homedir(), ".foundry", "bin"), "anvil"),
    ["--fork-url", network.rpcUrl, "--port", String(PORT), "--silent"],
    { stdio: "ignore" },
  );
  try {
    for (let i = 0; i < 60; i++) {
      try {
        await publicClient.getChainId();
        break;
      } catch {
        await new Promise((resolve) => setTimeout(resolve, 1000));
      }
    }

    // --- buy ---------------------------------------------------------------------
    const amountIn = parseEther("0.01");
    const { result: [quote] } = await publicClient.simulateContract({
      address: network.uniswap.quoter,
      abi: quoterAbi,
      functionName: "quoteExactInputSingle",
      args: [{ poolKey: d.poolKey, zeroForOne: true, exactAmount: amountIn, hookData: "0x" }],
    });
    const block = await publicClient.getBlock();
    const buy = encodeBuy(d.poolKey, amountIn, withSlippage(quote, 100n), block.timestamp + 600n);
    await send({
      address: network.uniswap.universalRouter,
      abi: universalRouterAbi,
      functionName: "execute",
      args: [buy.commands, buy.inputs, buy.deadline],
      value: amountIn,
    });
    const tenax = await publicClient.readContract({
      address: contracts.token,
      abi: erc20Abi,
      functionName: "balanceOf",
      args: [account.address],
    });
    console.log(`quote ${formatEther(quote)} TENAX, received ${formatEther(tenax)} TENAX`);
    check(tenax === quote, "the Universal Router buy delivers exactly the quoted TENAX");

    // --- lock --------------------------------------------------------------------
    const now = Number((await publicClient.getBlock()).timestamp);
    const end = roundDownToWeek(now + MAX_LOCK);
    // Enough for 5,000 veTENAX 60 days from now, as the dApp suggests: veTENAX decays from the moment of locking.
    const amount = amountForVe(MIN_VE, end, now + 60 * 86_400);
    check(tenax >= amount, `enough TENAX to keep 5,000 veTENAX for 60 days (${formatEther(amount)} needed)`);
    await send({ address: contracts.token, abi: erc20Abi, functionName: "approve", args: [contracts.escrow, amount] });
    await send({ address: contracts.escrow, abi: votingEscrowAbi, functionName: "createLock", args: [amount, BigInt(end)] });
    const ve = await publicClient.readContract({
      address: contracts.escrow,
      abi: votingEscrowAbi,
      functionName: "balanceOf",
      args: [account.address],
    });
    check(ve >= MIN_VE, `the lock gives ${formatEther(ve)} veTENAX, enough to forecast`);
    check(ve === veBalance(amount, end, Number((await publicClient.getBlock()).timestamp)), "veTENAX matches the local formula");

    // --- commit ------------------------------------------------------------------
    const [submission, reveal] = await Promise.all([
      publicClient.readContract({ address: contracts.registry, abi: forecastRegistryAbi, functionName: "submissionWindow" }),
      publicClient.readContract({ address: contracts.registry, abi: forecastRegistryAbi, functionName: "revealWindow" }),
    ]);
    const round = BigInt(Math.max(0, Math.ceil((now + 120 - d.genesis) / 86_400)));
    const schedule = roundSchedule(d.genesis, round, Number(submission), Number(reveal));
    await testClient.setNextBlockTimestamp({ timestamp: BigInt(schedule.open + 60) });
    await testClient.mine({ blocks: 1 });

    const signature = await account.signMessage({ message: forecastKeyMessage(account.address, d.chainId, contracts.registry) });
    const key = forecastKey(signature);
    const asset = 1n;
    const forecast = 6_250n;
    const salt = deriveSalt(key, asset, round);
    const ctx = { chainId: d.chainId, registry: contracts.registry, asset, round, participant: account.address };
    const local = commitmentHash(ctx, forecast, salt);
    const onChain = await publicClient.readContract({
      address: contracts.registry,
      abi: forecastRegistryAbi,
      functionName: "commitmentHash",
      args: [asset, round, account.address, forecast, salt],
    });
    check(local === onChain, "the local commitment hash equals the registry's");
    await send({ address: contracts.registry, abi: forecastRegistryAbi, functionName: "commit", args: [asset, round, local] });

    // --- reveal from a fresh device: re-sign, recover, reveal --------------------
    await testClient.setNextBlockTimestamp({ timestamp: BigInt(schedule.resolveTime + 60) });
    await testClient.mine({ blocks: 1 });
    const again = forecastKey(
      await account.signMessage({ message: forecastKeyMessage(account.address, d.chainId, contracts.registry) }),
    );
    check(again === key, "signing the forecast key message again gives the same key");
    const stored = await publicClient.readContract({
      address: contracts.registry,
      abi: forecastRegistryAbi,
      functionName: "commitmentOf",
      args: [asset, round, account.address],
    });
    const recovered = recoverForecast(ctx, stored.hash, deriveSalt(again, asset, round));
    check(recovered === forecast, "the forecast is recovered from the on-chain commitment");
    await send({
      address: contracts.registry,
      abi: forecastRegistryAbi,
      functionName: "reveal",
      args: [asset, round, recovered!, salt],
    });
    const after = await publicClient.readContract({
      address: contracts.registry,
      abi: forecastRegistryAbi,
      functionName: "commitmentOf",
      args: [asset, round, account.address],
    });
    check(after.revealed && BigInt(after.forecast) === forecast, "the reveal is recorded");
    console.log("fork check complete");
  } finally {
    anvil.kill();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
