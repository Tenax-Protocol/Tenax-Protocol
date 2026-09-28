// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Builds OpenZeppelin-compatible Merkle trees (sorted pairs, double-hashed leaves) for tests. The number of
/// leaves must be a power of two.
library MerkleHelper {
    function leaf(address account, uint256 maxAmount) internal pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(account, maxAmount))));
    }

    function root(bytes32[] memory leaves) internal pure returns (bytes32) {
        bytes32[] memory level = leaves;
        while (level.length > 1) {
            level = _next(level);
        }
        return level[0];
    }

    function proof(bytes32[] memory leaves, uint256 index) internal pure returns (bytes32[] memory path) {
        uint256 depth;
        for (uint256 n = leaves.length; n > 1; n /= 2) {
            ++depth;
        }
        path = new bytes32[](depth);
        bytes32[] memory level = leaves;
        for (uint256 d; d < depth; ++d) {
            path[d] = level[index ^ 1];
            level = _next(level);
            index /= 2;
        }
    }

    function _next(bytes32[] memory level) private pure returns (bytes32[] memory up) {
        require(level.length % 2 == 0, "leaves must be a power of two");
        up = new bytes32[](level.length / 2);
        for (uint256 i; i < up.length; ++i) {
            up[i] = _hashPair(level[2 * i], level[2 * i + 1]);
        }
    }

    function _hashPair(bytes32 a, bytes32 b) private pure returns (bytes32) {
        return a < b ? keccak256(abi.encode(a, b)) : keccak256(abi.encode(b, a));
    }
}
