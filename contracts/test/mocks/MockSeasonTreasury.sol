// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ISeasonTreasury} from "../../src/interfaces/ISeasonTreasury.sol";

/// @dev Treasury stand-in that never tops up, so season budgets come from emissions and revenue only.
contract MockSeasonTreasury is ISeasonTreasury {
    uint256 public settledSeasons;
    bool public lastHadParticipants;

    function settleSeason(uint256, uint256, bool hasParticipants) external returns (uint256) {
        ++settledSeasons;
        lastHadParticipants = hasParticipants;
        return 0;
    }
}
