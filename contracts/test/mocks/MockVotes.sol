// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @dev Vote escrow stand-in: only `getVotes` is used by the forecast registry.
contract MockVotes {
    mapping(address account => uint256 votes) public getVotes;

    function setVotes(address account, uint256 votes) external {
        getVotes[account] = votes;
    }
}
