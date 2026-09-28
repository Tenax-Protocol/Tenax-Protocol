// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3} from "../../src/forecast/OracleAdapter.sol";

/// @dev Chainlink aggregator with rounds pushed by the test, in increasing time order.
contract MockAggregator is IAggregatorV3 {
    struct Data {
        int256 answer;
        uint256 startedAt;
        uint256 updatedAt;
    }

    uint8 public immutable decimals;
    uint80 public latestRound;
    bool public revertOnMissingRound = true;
    mapping(uint80 roundId => Data) internal _rounds;

    constructor(uint8 decimals_) {
        decimals = decimals_;
    }

    function push(int256 answer, uint256 startedAt, uint256 updatedAt) external returns (uint80 roundId) {
        roundId = ++latestRound;
        _rounds[roundId] = Data(answer, startedAt, updatedAt);
    }

    /// @dev Simulates a Chainlink phase change: proxy round ids jump to a new phase, leaving a gap.
    function pushWithId(uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt) external {
        require(roundId > latestRound, "round ids must increase");
        latestRound = roundId;
        _rounds[roundId] = Data(answer, startedAt, updatedAt);
    }

    /// @dev Some Chainlink proxies revert for missing rounds, others return zeros; both must be handled.
    function setRevertOnMissingRound(bool value) external {
        revertOnMissingRound = value;
    }

    function getRoundData(uint80 roundId) public view returns (uint80, int256, uint256, uint256, uint80) {
        if (roundId == 0 || roundId > latestRound || _rounds[roundId].updatedAt == 0) {
            if (revertOnMissingRound) revert("No data present");
            return (roundId, 0, 0, 0, 0);
        }
        Data memory d = _rounds[roundId];
        return (roundId, d.answer, d.startedAt, d.updatedAt, roundId);
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return getRoundData(latestRound);
    }
}
