// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";

/// @dev Forecast registry stand-in exposing only what SeasonRewards reads, with contributions set by the test.
contract MockSeasonRegistry {
    uint256 public constant ROUND_INTERVAL = 1 days;
    uint256 public constant HORIZON = 24 hours;
    uint256 public constant SEASON_LENGTH = 30 days;
    uint256 public constant MAX_SUBMISSION_WINDOW = 6 hours;
    uint256 public constant MAX_REVEAL_WINDOW = 7 days;
    uint256 public constant assetCount = 2;

    uint256 public immutable genesis;
    uint256 public nextRoundToResolve;
    uint256 public settleCalls;

    mapping(address participant => mapping(uint256 season => uint128 contribution)) public contributionOf;

    constructor(uint256 genesis_) {
        genesis = genesis_;
    }

    function setNextRoundToResolve(uint256 round) external {
        nextRoundToResolve = round;
    }

    function setContribution(address participant, uint256 season, uint128 contribution) external {
        contributionOf[participant][season] = contribution;
    }

    function settle(address) external {
        ++settleCalls;
    }

    function assetState(uint256) external view returns (ForecastRegistry.AssetState memory state) {
        state.nextRoundToResolve = nextRoundToResolve;
    }

    function seasonStats(address participant, uint256 season)
        external
        view
        returns (ForecastRegistry.SeasonStats memory stats)
    {
        stats.contribution = contributionOf[participant][season];
    }
}
