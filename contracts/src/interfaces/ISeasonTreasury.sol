// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice What season rewards need from the treasury: settling a season's TENAX reserve allowance.
interface ISeasonTreasury {
    /// @notice Settles `season`'s reserve allowance when the season closes: sends the top-up to the caller and
    /// burns the rest. Returns the top-up, which is zero when the season has no participants.
    function settleSeason(uint256 season, uint256 ethReceived, bool hasParticipants) external returns (uint256 topUp);
}
