// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VestingWallet} from "@openzeppelin/contracts/finance/VestingWallet.sol";

/// @title CreatorVesting
/// @notice Vests the creator allocation over 36 months: nothing for 12 months, then linear over the next 24,
/// with no lump sum at the cliff (whitepaper section 6.4).
/// @dev OpenZeppelin's VestingWallet with its linear schedule starting at the end of the cliff.
contract CreatorVesting is VestingWallet {
    uint64 public constant CLIFF = 365 days;
    uint64 public constant VESTING_DURATION = 730 days;

    /// @param beneficiary Creator address; owns the wallet and receives released tokens.
    /// @param launchTimestamp Protocol launch time, from which the cliff is counted.
    constructor(address beneficiary, uint64 launchTimestamp)
        VestingWallet(beneficiary, launchTimestamp + CLIFF, VESTING_DURATION)
    {}
}
