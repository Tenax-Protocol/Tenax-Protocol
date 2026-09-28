import assert from "node:assert/strict";
import { test } from "node:test";
import { type Address, getAddress, keccak256, toHex } from "viem";
import { allocate, isEligible, type ParticipantStats } from "./airdrop.js";
import { buildTree, leafHash, verifyProof } from "./merkle.js";

const account = (n: number): Address => getAddress(`0x${n.toString(16).padStart(40, "0")}`);

/** Stats for `rounds` rounds of constant skill `s` (1e8 units). */
const constant = (n: number, rounds: bigint, s: bigint): ParticipantStats => ({
  account: account(n),
  rounds,
  skillSum: s * rounds,
  skillSquares: s * s * rounds,
});

test("eligibility requires 20 rounds, a mean skill floor and significance", () => {
  assert.ok(isEligible(constant(1, 20n, 1_000_000n)));
  assert.ok(!isEligible(constant(1, 19n, 1_000_000n)), "too few rounds");
  assert.ok(!isEligible(constant(1, 30n, 299_999n)), "mean below 0.003");
  assert.ok(!isEligible({ account: account(1), rounds: 30n, skillSum: 0n, skillSquares: 0n }), "no skill");
  // Mean 0.01 but very noisy: z = 3e7 / sqrt(30 * 4e15) ~ 0.087, far from 1.64.
  assert.ok(!isEligible({ account: account(1), rounds: 30n, skillSum: 30_000_000n, skillSquares: 30n * 4_000_000_000_000_000n }));
});

test("the z test is exact at its boundary", () => {
  // With sum = 164k and squares = 10,000k^2, z = 164k / 100k = 1.64 exactly.
  const k = 1_000_000n;
  const atBoundary = { account: account(1), rounds: 20n, skillSum: 164n * k, skillSquares: 10_000n * k * k };
  assert.ok(isEligible(atBoundary));
  assert.ok(!isEligible({ ...atBoundary, skillSquares: atBoundary.skillSquares + 1n }));
});

test("half of the budget is split equally and half by skill, never exceeding it", () => {
  const budget = 10_000_000n * 10n ** 18n;
  const eligible = [constant(1, 30n, 1_000_000n), constant(2, 30n, 3_000_000n), constant(3, 25n, 500_000n)];
  const allocations = allocate(eligible, budget);
  const total = allocations.reduce((sum, a) => sum + a.amount, 0n);
  assert.ok(total <= budget);
  assert.ok(budget - total < 10n, "only rounding dust left");
  const equal = budget / 2n / 3n;
  const totalSkill = 30_000_000n + 90_000_000n + 12_500_000n;
  assert.equal(allocations[1]!.amount, equal + ((budget - budget / 2n) * 90_000_000n) / totalSkill);
  assert.ok(allocations[1]!.amount > allocations[0]!.amount);
  assert.deepEqual(allocate([], budget), []);
});

test("every proof verifies against the root, for any number of leaves", () => {
  for (const count of [1, 2, 3, 5, 8, 13]) {
    const leaves = Array.from({ length: count }, (_, i) => leafHash(account(i + 1), BigInt(i + 1) * 10n ** 18n));
    const tree = buildTree(leaves);
    leaves.forEach((leaf, i) => assert.ok(verifyProof(leaf, tree.proof(i), tree.root), `leaf ${i} of ${count}`));
    assert.ok(!verifyProof(keccak256(toHex("other")), tree.proof(0), tree.root) || count === 1);
  }
});

test("leaves use the double-hashed standard encoding", () => {
  // keccak256(bytes.concat(keccak256(abi.encode(address(1), 1e18)))), computed independently.
  const expected = keccak256(
    keccak256(`0x${"0".repeat(63)}1${(10n ** 18n).toString(16).padStart(64, "0")}`),
  );
  assert.equal(leafHash(account(1), 10n ** 18n), expected);
});
