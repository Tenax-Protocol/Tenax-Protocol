import assert from "node:assert/strict";
import { test } from "node:test";
import { type QueryRange, scanRanges } from "./logs.js";

/** In-memory provider that rejects ranges wider than `limit` and records every range it answers. */
function provider(limit: bigint): { query: QueryRange<bigint>; ranges: Array<[bigint, bigint]> } {
  const ranges: Array<[bigint, bigint]> = [];
  const query: QueryRange<bigint> = async (from, to) => {
    if (to - from + 1n > limit) throw new Error(`limited to a ${limit} range`);
    ranges.push([from, to]);
    const blocks: bigint[] = [];
    for (let block = from; block <= to; block++) blocks.push(block);
    return blocks;
  };
  return { query, ranges };
}

const blocks = (from: bigint, to: bigint) => Array.from({ length: Number(to - from + 1n) }, (_, i) => from + BigInt(i));

test("covers the range in chunks, the last one cut at the end", async () => {
  const { query, ranges } = provider(1_000n);
  assert.deepEqual(await scanRanges(10n, 2_509n, 1_000n, query), blocks(10n, 2_509n));
  assert.deepEqual(ranges, [
    [10n, 1_009n],
    [1_010n, 2_009n],
    [2_010n, 2_509n],
  ]);
});

test("halves the chunk when the provider rejects the range, and keeps it", async () => {
  const { query, ranges } = provider(500n);
  assert.deepEqual(await scanRanges(0n, 1_199n, 1_000n, query), blocks(0n, 1_199n));
  assert.deepEqual(ranges, [
    [0n, 499n],
    [500n, 999n],
    [1_000n, 1_199n],
  ]);
});

test("rethrows when even a single block is rejected", async () => {
  const query: QueryRange<bigint> = async () => {
    throw new Error("unauthorized");
  };
  await assert.rejects(scanRanges(0n, 99n, 64n, query), /unauthorized/);
});

test("returns nothing when the range is empty", async () => {
  const { query, ranges } = provider(1_000n);
  assert.deepEqual(await scanRanges(5n, 4n, 1_000n, query), []);
  assert.deepEqual(ranges, []);
});
