// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BrierMath} from "../../src/forecast/BrierMath.sol";
import {Test} from "forge-std/Test.sol";

contract BrierMathTest is Test {
    function test_brier_knownValues() public pure {
        assertEq(BrierMath.brier(0, false), 0);
        assertEq(BrierMath.brier(10_000, true), 0);
        assertEq(BrierMath.brier(10_000, false), 1e8);
        assertEq(BrierMath.brier(5000, true), 2.5e7);
        assertEq(BrierMath.brier(3600, false), 1.296e7);
    }

    function test_skill_isZeroWhenForecastEqualsBaseRate() public pure {
        assertEq(BrierMath.skill(3600, 3600, true), 0);
        assertEq(BrierMath.skill(3600, 3600, false), 0);
    }

    function test_skill_perfectForecast() public pure {
        // B(b, 1) = (1 - 0.36)^2 = 0.4096; a perfect forecast scores B = 0.
        assertEq(BrierMath.skill(10_000, 3600, true), 4.096e7);
        assertEq(BrierMath.skill(0, 3600, false), 1.296e7);
    }

    function test_missedRevealSkill_scoresTheWorstForecast() public pure {
        assertEq(BrierMath.missedRevealSkill(3600, true), 4.096e7 - 1e8);
        assertEq(BrierMath.missedRevealSkill(3600, false), 1.296e7 - 1e8);
    }

    function test_updateReputation() public pure {
        assertEq(BrierMath.updateReputation(0, 3200), 100);
        assertEq(BrierMath.updateReputation(3200, 3200), 3200);
        assertEq(BrierMath.updateReputation(0, -3200), -100);
    }

    function test_weight_knownValues() public pure {
        assertEq(BrierMath.weight(-5e6), 1e18);
        assertEq(BrierMath.weight(0), 1e18);
        assertEq(BrierMath.weight(0.01e8), 1.5e18); // EMA 0.01 with K = 50
        assertEq(BrierMath.weight(0.02e8), 2e18);
        assertEq(BrierMath.weight(0.5e8), 2e18); // capped
    }

    function test_isEligible_requiresTwentyRoundsInTheSeason() public pure {
        assertFalse(BrierMath.isEligible(19, 60, 60e6, 1e12));
        assertTrue(BrierMath.isEligible(20, 60, 60e6, 1e12));
    }

    function test_isEligible_requiresPositiveSkill() public pure {
        assertFalse(BrierMath.isEligible(60, 60, 0, 0));
        assertFalse(BrierMath.isEligible(60, 60, -1, 1));
    }

    function test_isEligible_requiresMinimumMeanSkill() public pure {
        // 60 rounds need a sum of at least 60 * 0.003 = 1.8e7.
        assertFalse(BrierMath.isEligible(60, 60, 1.8e7 - 1, 1));
        assertTrue(BrierMath.isEligible(60, 60, 1.8e7, 1));
    }

    function test_isEligible_zTestBoundary() public pure {
        // z = sum / sqrt(squares) >= 1.64 <=> sum^2 >= 2.6896 * squares.
        int256 sum = 1.64e8;
        assertTrue(BrierMath.isEligible(20, 20, sum, 1e16)); // z exactly 1.64
        assertFalse(BrierMath.isEligible(20, 20, sum, 1e16 + 1));
    }

    function test_absoluteReturn() public pure {
        assertEq(BrierMath.absoluteReturn(100e18, 102e18), 0.02e18);
        assertEq(BrierMath.absoluteReturn(100e18, 98e18), 0.02e18);
        assertEq(BrierMath.absoluteReturn(100e18, 100e18), 0);
    }

    function test_updateThreshold() public pure {
        assertEq(BrierMath.updateThreshold(0.02e18, 0.05e18), 0.021e18);
        assertEq(BrierMath.updateThreshold(0.03e18, 0), 0.029e18);
    }

    function test_updateBaseRate() public pure {
        assertEq(BrierMath.updateBaseRate(0.36e18, true), 0.36e18 + uint256(0.64e18) / 365);
        assertEq(BrierMath.updateBaseRate(0.365e18, false), 0.364e18);
    }

    function test_toBps_roundsHalfUp() public pure {
        assertEq(BrierMath.toBps(0.36e18), 3600);
        assertEq(BrierMath.toBps(0.123456e18), 1235);
        assertEq(BrierMath.toBps(0.12344e18), 1234);
        assertEq(BrierMath.toBps(1e18), 10_000);
        assertEq(BrierMath.toBps(0), 0);
    }
}
