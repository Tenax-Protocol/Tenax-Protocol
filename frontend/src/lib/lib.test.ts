import assert from "node:assert/strict";
import { test } from "node:test";
import { getAddress, keccak256, toHex } from "viem";
import { MAX_LOCK, WEEK } from "./config.js";
import { amountForVe, earlyExitPenalty, roundDownToWeek, veBalance } from "./escrow.js";
import { commitmentHash, currentRound, deriveSalt, forecastKey, recoverForecast, roundSchedule } from "./forecast.js";
import { passesTests, zScore } from "./stats.js";
import { withSlippage } from "./swap.js";

const ctx = {
  chainId: 84_532,
  registry: getAddress("0xb180d2d683a08a26e4810639cb2aa39a286c630e"),
  asset: 1n,
  round: 42n,
  participant: getAddress("0x25a02c80769fd2dea519a44b1d4208ffc6794804"),
};

test("salts are deterministic per round and asset", () => {
  const key = forecastKey(keccak256(toHex("a signature")));
  assert.equal(deriveSalt(key, 0n, 5n), deriveSalt(key, 0n, 5n));
  assert.notEqual(deriveSalt(key, 0n, 5n), deriveSalt(key, 1n, 5n));
  assert.notEqual(deriveSalt(key, 0n, 5n), deriveSalt(key, 0n, 6n));
});

test("the forecast behind a commitment is recovered from its salt", () => {
  const salt = deriveSalt(forecastKey(keccak256(toHex("key"))), ctx.asset, ctx.round);
  for (const forecast of [0n, 1n, 3_600n, 9_999n, 10_000n]) {
    assert.equal(recoverForecast(ctx, commitmentHash(ctx, forecast, salt), salt), forecast);
  }
  const otherSalt = deriveSalt(forecastKey(keccak256(toHex("other"))), ctx.asset, ctx.round);
  assert.equal(recoverForecast(ctx, commitmentHash(ctx, 5_000n, salt), otherSalt), null);
});

test("round schedule follows the registry", () => {
  const genesis = 1_790_640_000;
  const s = roundSchedule(genesis, 3n, 1800, 172_800);
  assert.equal(s.open, genesis + 3 * 86_400);
  assert.equal(s.commitEnd, s.open + 1800);
  assert.equal(s.resolveTime, s.commitEnd + 86_400);
  assert.equal(s.revealEnd, s.resolveTime + 172_800);
  assert.equal(currentRound(genesis, genesis - 1), null);
  assert.equal(currentRound(genesis, genesis + 86_399), 0n);
  assert.equal(currentRound(genesis, genesis + 86_400), 1n);
});

test("early exit penalty matches the escrow: capped at 50%, rounded up", () => {
  const amount = 1_000n * 10n ** 18n;
  assert.equal(earlyExitPenalty(amount, 0), 0n);
  assert.equal(earlyExitPenalty(amount, MAX_LOCK / 4), amount / 4n);
  assert.equal(earlyExitPenalty(amount, MAX_LOCK / 2), amount / 2n);
  assert.equal(earlyExitPenalty(amount, MAX_LOCK), amount / 2n, "cap");
  assert.equal(earlyExitPenalty(1n, 1), 1n, "rounds up in the protocol's favor");
});

test("veTENAX decays linearly and the minimum amount for a target holds", () => {
  const now = 1_790_000_000;
  const end = roundDownToWeek(now + MAX_LOCK);
  assert.equal(end % WEEK, 0);
  const amount = amountForVe(5_000n * 10n ** 18n, end, now);
  assert.ok(veBalance(amount, end, now) >= 5_000n * 10n ** 18n);
  assert.ok(veBalance(amount - BigInt(MAX_LOCK), end, now) < 5_000n * 10n ** 18n, "one slope unit less falls short");
  assert.equal(veBalance(amount, end, end), 0n);
});

test("significance matches the season tests", () => {
  const k = 1_000_000n;
  const boundary = { rounds: 20n, skillSum: 164n * k, skillSquares: 10_000n * k * k };
  assert.ok(passesTests(20n, boundary));
  assert.ok(!passesTests(19n, boundary), "fewer than 20 rounds in the season");
  assert.ok(!passesTests(20n, { ...boundary, skillSquares: boundary.skillSquares + 1n }));
  assert.ok(Math.abs(zScore(boundary) - 1.64) < 1e-9);
});

test("slippage lowers the minimum output", () => {
  assert.equal(withSlippage(10_000n, 100n), 9_900n);
});
