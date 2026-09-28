import { writeFileSync } from "node:fs";
import { join } from "node:path";
import { type Address, getAddress } from "viem";
import { repoRoot } from "../lib/context.js";
import { buildTree, leafHash } from "../lib/merkle.js";

/** Where the Solidity test that claims against MerkleAirdrop reads the fixture from. */
export const fixturePath = join(repoRoot, "contracts", "test", "fixtures", "airdrop-tree.json");

/** A fixed tree with an odd number of leaves, built exactly as the airdrop tool builds real ones. */
export function fixtureJson(): string {
  const recipients = Array.from({ length: 7 }, (_, i) => ({
    account: getAddress(`0x${(0x1000 + i).toString(16).padStart(40, "0")}`) as Address,
    amount: BigInt(i + 1) * 123_456_789_000_000_000_000n,
  }));
  const tree = buildTree(recipients.map((r) => leafHash(r.account, r.amount)));
  const json = {
    root: tree.root,
    recipients: recipients.map((r, i) => ({ account: r.account, amount: r.amount.toString(), proof: tree.proof(i) })),
  };
  return `${JSON.stringify(json, null, 2)}\n`;
}

if (process.argv[1]?.endsWith("fixture.ts")) {
  writeFileSync(fixturePath, fixtureJson());
  console.log(`wrote ${fixturePath}`);
}
