import { type Address, concat, encodeAbiParameters, type Hex, keccak256 } from "viem";

/**
 * Merkle trees in the encoding MerkleAirdrop verifies, the same as OpenZeppelin's standard tree:
 * leaves are `keccak256(bytes.concat(keccak256(abi.encode(account, amount))))` and pairs are hashed in sorted order.
 */
export function leafHash(account: Address, amount: bigint): Hex {
  return keccak256(keccak256(encodeAbiParameters([{ type: "address" }, { type: "uint256" }], [account, amount])));
}

function hashPair(a: Hex, b: Hex): Hex {
  return BigInt(a) < BigInt(b) ? keccak256(concat([a, b])) : keccak256(concat([b, a]));
}

export interface MerkleTree {
  root: Hex;
  proof(index: number): Hex[];
}

/** Builds a tree over `leaves` in the given order; an unpaired node moves up a level unchanged. */
export function buildTree(leaves: Hex[]): MerkleTree {
  if (leaves.length === 0) throw new Error("a Merkle tree needs at least one leaf");
  const levels: Hex[][] = [leaves];
  while (levels[levels.length - 1]!.length > 1) {
    const level = levels[levels.length - 1]!;
    const next: Hex[] = [];
    for (let i = 0; i < level.length; i += 2) {
      next.push(i + 1 < level.length ? hashPair(level[i]!, level[i + 1]!) : level[i]!);
    }
    levels.push(next);
  }
  return {
    root: levels[levels.length - 1]![0]!,
    proof(index) {
      const path: Hex[] = [];
      for (let depth = 0; depth < levels.length - 1; depth++) {
        const level = levels[depth]!;
        const sibling = index ^ 1;
        if (sibling < level.length) path.push(level[sibling]!);
        index >>= 1;
      }
      return path;
    },
  };
}

/** Recomputes the root from a leaf and its proof, as MerkleProof.verify does. */
export function verifyProof(leaf: Hex, proof: Hex[], root: Hex): boolean {
  let hash = leaf;
  for (const sibling of proof) hash = hashPair(hash, sibling);
  return hash === root;
}
