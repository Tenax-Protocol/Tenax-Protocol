// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title BrierMath
/// @notice Scoring arithmetic of the forecasting network (whitepaper sections 3.2 to 3.6 and 5.6).
/// @dev Units:
/// - probabilities (forecasts, base rate, aggregate) are basis points, 0 to 10,000;
/// - Brier scores and skill are in squared basis points, so 1.0 = 1e8;
/// - the threshold, absolute returns and the base rate state are 1e18 fixed-point fractions;
/// - aggregation weights are 1e18 fixed point, from 1e18 to 2e18.
library BrierMath {
    uint256 internal constant BPS = 10_000;

    /// @notice 1.0 in skill units (squared basis points).
    int256 internal constant SKILL_ONE = 1e8;

    uint256 internal constant WAD = 1e18;

    /// @notice Aggregation weight factor K.
    uint256 internal constant WEIGHT_FACTOR = 50;

    /// @notice Reputation EMA factor alpha = 1/32.
    int256 internal constant EMA_DIVISOR = 32;

    /// @notice Threshold EMA factor beta = 1/30.
    int256 internal constant THRESHOLD_DIVISOR = 30;

    /// @notice Base rate EMA factor gamma = 1/365.
    int256 internal constant BASE_RATE_DIVISOR = 365;

    /// @notice Minimum rounds in the season being rewarded.
    uint256 internal constant MIN_SEASON_ROUNDS = 20;

    /// @notice Minimum mean skill over the eligibility window: 0.003.
    int256 internal constant MIN_MEAN_SKILL = 300_000;

    /// @notice z >= 1.64, compared squared: 1.64^2 = 2.6896, in basis points.
    uint256 internal constant Z_SQUARED_BPS = 26_896;

    /// @notice Brier score of forecast `p` (bps) for outcome `outcome`, in skill units.
    function brier(uint256 p, bool outcome) internal pure returns (uint256) {
        uint256 distance = outcome ? BPS - p : p;
        return distance * distance;
    }

    /// @notice Skill of forecast `p` against the base rate `b` (both bps): B(b, o) - B(p, o).
    function skill(uint256 p, uint256 b, bool outcome) internal pure returns (int256) {
        return SafeCast.toInt256(brier(b, outcome)) - SafeCast.toInt256(brier(p, outcome));
    }

    /// @notice Skill of a commitment that was never revealed: scored as the worst forecast, B = 1.
    function missedRevealSkill(uint256 b, bool outcome) internal pure returns (int256) {
        return SafeCast.toInt256(brier(b, outcome)) - SKILL_ONE;
    }

    /// @notice Reputation update: EMA += (S - EMA) / 32.
    function updateReputation(int256 ema, int256 skillValue) internal pure returns (int256) {
        return ema + (skillValue - ema) / EMA_DIVISOR;
    }

    /// @notice Aggregation weight w = min(1 + K * max(EMA, 0), 2), in 1e18 fixed point.
    function weight(int256 ema) internal pure returns (uint256) {
        if (ema <= 0) return WAD;
        // EMA is in 1e8 units; scaling to 1e18 multiplies by 1e10.
        uint256 w = WAD + WEIGHT_FACTOR * SafeCast.toUint256(ema) * 1e10;
        return w < 2 * WAD ? w : 2 * WAD;
    }

    /// @notice Whether a participant is eligible for a season's rewards.
    /// @param seasonRounds Rounds scored in the season being rewarded.
    /// @param windowRounds Rounds scored over the eligibility window (this season and the two before).
    /// @param windowSkill Sum of skill over the window.
    /// @param windowSkillSquares Sum of squared skill over the window.
    function isEligible(uint256 seasonRounds, uint256 windowRounds, int256 windowSkill, uint256 windowSkillSquares)
        internal
        pure
        returns (bool)
    {
        if (seasonRounds < MIN_SEASON_ROUNDS || windowSkill <= 0) return false;
        if (windowSkill < MIN_MEAN_SKILL * SafeCast.toInt256(windowRounds)) return false;
        // z = sum / sqrt(sumSquares) >= 1.64, without a square root.
        uint256 sum = SafeCast.toUint256(windowSkill);
        return sum * sum * BPS >= Z_SQUARED_BPS * windowSkillSquares;
    }

    /// @notice |close / ref - 1| as a 1e18 fraction.
    function absoluteReturn(uint256 ref, uint256 close) internal pure returns (uint256) {
        uint256 difference = close > ref ? close - ref : ref - close;
        return difference * WAD / ref;
    }

    /// @notice Threshold update: X += (|r| - X) / 30.
    function updateThreshold(uint256 threshold, uint256 absReturn) internal pure returns (uint256) {
        int256 current = SafeCast.toInt256(threshold);
        return SafeCast.toUint256(current + (SafeCast.toInt256(absReturn) - current) / THRESHOLD_DIVISOR);
    }

    /// @notice Base rate update: b += (o - b) / 365.
    function updateBaseRate(uint256 baseRate, bool outcome) internal pure returns (uint256) {
        int256 current = SafeCast.toInt256(baseRate);
        int256 target = outcome ? SafeCast.toInt256(WAD) : int256(0);
        return SafeCast.toUint256(current + (target - current) / BASE_RATE_DIVISOR);
    }

    /// @notice Converts a 1e18 fraction to basis points, rounding half up.
    function toBps(uint256 fraction) internal pure returns (uint256) {
        return (fraction * BPS + WAD / 2) / WAD;
    }
}
