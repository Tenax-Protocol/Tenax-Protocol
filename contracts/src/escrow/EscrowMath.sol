// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title EscrowMath
/// @notice Pure arithmetic of the vote escrow, kept apart so it can be tested in isolation.
library EscrowMath {
    uint256 internal constant WEEK = 7 days;

    /// @notice Maximum lock duration: 104 weeks.
    uint256 internal constant MAX_LOCK = 104 weeks;

    /// @notice Minimum lock duration: 1 week.
    uint256 internal constant MIN_LOCK = 1 weeks;

    /// @notice Rounds a timestamp down to the start of its week.
    function roundDownToWeek(uint256 timestamp) internal pure returns (uint256) {
        // Truncating division is the rounding itself.
        // forge-lint: disable-next-line(divide-before-multiply)
        return (timestamp / WEEK) * WEEK;
    }

    /// @notice Decay rate of a lock: ve units lost per second.
    function slope(uint256 amount) internal pure returns (uint256) {
        return amount / MAX_LOCK;
    }

    /// @notice Penalty to exit `voluntary` tokens early with `remaining` seconds left:
    /// voluntary * min(remaining / MAX_LOCK, 50%), rounded up in the protocol's favor.
    /// @dev The product is at most 1e26 * 3.1e7, far below 2^256, so no 512-bit arithmetic is needed.
    function earlyExitPenalty(uint256 voluntary, uint256 remaining) internal pure returns (uint256) {
        uint256 capped = remaining < MAX_LOCK / 2 ? remaining : MAX_LOCK / 2;
        return (voluntary * capped + MAX_LOCK - 1) / MAX_LOCK;
    }
}
