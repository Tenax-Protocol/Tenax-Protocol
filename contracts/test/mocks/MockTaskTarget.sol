// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Keeper task target: `work` spends gas proportional to its argument, `fail` always reverts.
contract MockTaskTarget {
    uint256 public calls;
    mapping(uint256 slot => uint256 value) public data;

    error TaskFailed();

    function work(uint256 writes) external {
        ++calls;
        for (uint256 i; i < writes; ++i) {
            data[i] = block.timestamp + i;
        }
    }

    function fail() external pure {
        revert TaskFailed();
    }
}
