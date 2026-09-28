// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BrierMath} from "../../src/forecast/BrierMath.sol";
import {Test} from "forge-std/Test.sol";

contract BrierMathFuzzTest is Test {
    /// @dev Strict properness (whitepaper 3.4): if the event has true probability q, no forecast p has a higher
    /// expected skill than p = q, whatever the base rate.
    function testFuzz_honestForecastMaximizesExpectedSkill(uint256 q, uint256 p, uint256 b) public pure {
        q = bound(q, 0, 10_000);
        p = bound(p, 0, 10_000);
        b = bound(b, 0, 10_000);
        assertGe(_expectedSkill(q, q, b), _expectedSkill(p, q, b));
        if (p != q) assertGt(_expectedSkill(q, q, b), _expectedSkill(p, q, b), "strictly proper");
    }

    /// @dev Answering the base rate always scores exactly zero.
    function testFuzz_answeringTheBaseRateScoresZero(uint256 b, bool outcome) public pure {
        b = bound(b, 0, 10_000);
        assertEq(BrierMath.skill(b, b, outcome), 0);
    }

    function testFuzz_skillMatchesDefinitionAndBounds(uint256 p, uint256 b, bool outcome) public pure {
        p = bound(p, 0, 10_000);
        b = bound(b, 0, 10_000);
        int256 s = BrierMath.skill(p, b, outcome);
        int256 o = outcome ? int256(10_000) : int256(0);
        assertEq(s, (int256(b) - o) ** 2 - (int256(p) - o) ** 2);
        assertLe(s, int256(BrierMath.brier(b, outcome)));
        assertGe(s, int256(BrierMath.brier(b, outcome)) - 1e8);
    }

    /// @dev Not revealing is never better than revealing any forecast.
    function testFuzz_missingARevealIsTheWorstScore(uint256 p, uint256 b, bool outcome) public pure {
        p = bound(p, 0, 10_000);
        b = bound(b, 0, 10_000);
        assertLe(BrierMath.missedRevealSkill(b, outcome), BrierMath.skill(p, b, outcome));
    }

    function testFuzz_weightIsBoundedAndMonotonic(int256 lower, int256 higher) public pure {
        lower = bound(lower, -1e8, 1e8);
        higher = bound(higher, lower, 1e8);
        uint256 wLow = BrierMath.weight(lower);
        uint256 wHigh = BrierMath.weight(higher);
        assertGe(wLow, 1e18);
        assertLe(wHigh, 2e18);
        assertLe(wLow, wHigh);
    }

    function testFuzz_reputationStaysBetweenOldValueAndNewSkill(int256 ema, int256 s) public pure {
        ema = bound(ema, -1e8, 1e8);
        s = bound(s, -1e8, 1e8);
        int256 next = BrierMath.updateReputation(ema, s);
        assertGe(next, ema < s ? ema : s);
        assertLe(next, ema < s ? s : ema);
    }

    function testFuzz_thresholdMovesTowardTheObservedReturn(uint256 threshold, uint256 absReturn) public pure {
        threshold = bound(threshold, 1, 1e18);
        absReturn = bound(absReturn, 0, 10e18);
        uint256 next = BrierMath.updateThreshold(threshold, absReturn);
        assertGe(next, threshold < absReturn ? threshold : absReturn);
        assertLe(next, threshold < absReturn ? absReturn : threshold);
    }

    function testFuzz_baseRateStaysAProbability(uint256 b, bool outcome) public pure {
        b = bound(b, 0, 1e18);
        uint256 next = BrierMath.updateBaseRate(b, outcome);
        assertLe(next, 1e18);
        if (outcome) assertGe(next, b);
        else assertLe(next, b);
    }

    function testFuzz_toBpsIsWithinHalfABasisPoint(uint256 fraction) public pure {
        fraction = bound(fraction, 0, 1e18);
        uint256 bps = BrierMath.toBps(fraction);
        assertLe(bps, 10_000);
        uint256 back = bps * 1e14;
        uint256 error = back > fraction ? back - fraction : fraction - back;
        assertLe(error, 0.5e14);
    }

    function testFuzz_absoluteReturnIsSymmetricInDirection(uint256 ref, uint256 move) public pure {
        ref = bound(ref, 1e18, 1e30);
        move = bound(move, 0, ref - 1);
        assertEq(BrierMath.absoluteReturn(ref, ref + move), BrierMath.absoluteReturn(ref, ref - move));
    }

    /// @dev Expected skill of forecast p when the event happens with probability q, scaled by 1e4.
    function _expectedSkill(uint256 p, uint256 q, uint256 b) internal pure returns (int256) {
        return int256(q) * BrierMath.skill(p, b, true) + int256(10_000 - q) * BrierMath.skill(p, b, false);
    }
}
