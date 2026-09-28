import { concat, encodeAbiParameters, type Hex, parseAbi, toHex } from "viem";
import type { Deployment } from "./config.js";

/**
 * Buying TENAX with native ETH through Uniswap's Universal Router: one V4_SWAP command that swaps an exact ETH
 * input in the protocol's pool, pays the ETH owed (SETTLE_ALL) and takes the TENAX bought (TAKE_ALL). Native ETH
 * needs no approval.
 */

const V4_SWAP = 0x10;
const SWAP_EXACT_IN_SINGLE = 0x06;
const SETTLE_ALL = 0x0c;
const TAKE_ALL = 0x0f;

export const universalRouterAbi = parseAbi([
  "function execute(bytes commands, bytes[] inputs, uint256 deadline) payable",
]);

export const quoterAbi = parseAbi([
  "struct PoolKey { address currency0; address currency1; uint24 fee; int24 tickSpacing; address hooks; }",
  "struct QuoteExactSingleParams { PoolKey poolKey; bool zeroForOne; uint128 exactAmount; bytes hookData; }",
  "function quoteExactInputSingle(QuoteExactSingleParams params) returns (uint256 amountOut, uint256 gasEstimate)",
]);

const poolKeyType = {
  type: "tuple",
  components: [
    { name: "currency0", type: "address" },
    { name: "currency1", type: "address" },
    { name: "fee", type: "uint24" },
    { name: "tickSpacing", type: "int24" },
    { name: "hooks", type: "address" },
  ],
} as const;

/** Arguments of `execute` that buy TENAX with `amountIn` wei, receiving at least `minOut`. */
export function encodeBuy(pool: Deployment["poolKey"], amountIn: bigint, minOut: bigint, deadline: bigint) {
  const actions = concat([
    toHex(SWAP_EXACT_IN_SINGLE, { size: 1 }),
    toHex(SETTLE_ALL, { size: 1 }),
    toHex(TAKE_ALL, { size: 1 }),
  ]);
  const swap = encodeAbiParameters(
    [
      {
        type: "tuple",
        components: [
          { name: "poolKey", ...poolKeyType },
          { name: "zeroForOne", type: "bool" },
          { name: "amountIn", type: "uint128" },
          { name: "amountOutMinimum", type: "uint128" },
          { name: "hookData", type: "bytes" },
        ],
      },
    ],
    [{ poolKey: pool, zeroForOne: true, amountIn, amountOutMinimum: minOut, hookData: "0x" }],
  );
  const settle = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [pool.currency0, amountIn]);
  const take = encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [pool.currency1, minOut]);
  const input = encodeAbiParameters([{ type: "bytes" }, { type: "bytes[]" }], [actions, [swap, settle, take]]);
  return { commands: toHex(V4_SWAP, { size: 1 }) as Hex, inputs: [input], deadline };
}

/** Minimum output after `slippageBps` of tolerance. */
export function withSlippage(quote: bigint, slippageBps: bigint): bigint {
  return (quote * (10_000n - slippageBps)) / 10_000n;
}
