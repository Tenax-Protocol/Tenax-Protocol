// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Properties of the emission curve, plus a differential check against an epoch-by-epoch reference.
contract EmissionScheduleFuzzTest is Test {
    uint256 internal constant START = 21_000_000;
    uint256 internal constant EPOCH = 2_628_000;

    EmissionSchedule internal schedule;

    function setUp() public {
        schedule = new EmissionSchedule(START);
    }

    function testFuzz_neverExceedsTheBucket(uint256 l1Block) public view {
        assertLe(schedule.emittedUntil(l1Block), schedule.BUCKET());
    }

    function testFuzz_isMonotonic(uint256 a, uint256 b) public view {
        (uint256 low, uint256 high) = a < b ? (a, b) : (b, a);
        assertLe(schedule.emittedUntil(low), schedule.emittedUntil(high));
    }

    function testFuzz_isMonotonicAroundEpochBoundaries(uint256 epochs, uint256 offset) public view {
        epochs = bound(epochs, 1, 2000);
        offset = bound(offset, 1, EPOCH);
        uint256 boundary = START + epochs * EPOCH;
        uint256 atBoundary = schedule.emittedUntil(boundary);
        assertEq(atBoundary, schedule.cumulativeAfter(epochs), "boundary equals cumulative");
        assertLe(schedule.emittedUntil(boundary - offset), atBoundary, "before boundary");
        assertGe(schedule.emittedUntil(boundary + offset), atBoundary, "after boundary");
    }

    function testFuzz_cumulativeIsMonotonic(uint256 epochs) public view {
        epochs = bound(epochs, 0, type(uint256).max - 1);
        assertLe(schedule.cumulativeAfter(epochs), schedule.cumulativeAfter(epochs + 1));
    }

    /// @dev Reference: add each floor epoch one by one, E_{k+1} = E_k * 0.85, in 1e18 precision.
    function testFuzz_matchesEpochByEpochReference(uint256 epochs) public view {
        epochs = bound(epochs, 6, 400);
        uint256 e1 = uint256(35_000_000e18) * 100 / 313;
        uint256 epochEmission = e1 * 168 / 1000;
        uint256 expected = schedule.cumulativeAfter(5);
        for (uint256 k = 6; k <= epochs; ++k) {
            epochEmission = epochEmission * 85 / 100;
            expected += epochEmission;
        }
        // Each floored epoch leaves up to 1 wei that later epochs carry at 0.85 per epoch, so the reference drifts
        // by at most 1 / 0.15 < 7 wei per epoch; the closed form rounds only once.
        assertApproxEqAbs(schedule.cumulativeAfter(epochs), expected, 7 * epochs);
    }

    function testFuzz_linearWithinAnEpoch(uint256 epochs, uint256 offset) public view {
        epochs = bound(epochs, 0, 100);
        offset = bound(offset, 0, EPOCH - 1);
        uint256 done = schedule.cumulativeAfter(epochs);
        uint256 current = schedule.cumulativeAfter(epochs + 1) - done;
        assertEq(schedule.emittedUntil(START + epochs * EPOCH + offset), done + current * offset / EPOCH);
    }
}
