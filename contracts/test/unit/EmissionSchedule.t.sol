// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {MockL1Block} from "../mocks/MockL1Block.sol";
import {Test} from "forge-std/Test.sol";

contract EmissionScheduleTest is Test {
    uint256 internal constant START = 21_000_000;
    uint256 internal constant EPOCH = 2_628_000;

    EmissionSchedule internal schedule;
    MockL1Block internal l1;

    function setUp() public {
        l1 = new MockL1Block().install(vm, uint64(START));
        schedule = new EmissionSchedule(START);
    }

    function test_nothingIsEmittedUpToTheStartBlock() public view {
        assertEq(schedule.emittedUntil(0), 0);
        assertEq(schedule.emittedUntil(START), 0);
        assertEq(schedule.emitted(), 0);
    }

    function test_firstEpoch_sizesTheInfiniteSeriesToTheBucket() public view {
        // E1 = 35M / 3.13, rounded down.
        assertEq(schedule.cumulativeAfter(1), uint256(35_000_000e18) * 100 / 313);
        assertEq(schedule.emittedUntil(START + EPOCH), schedule.cumulativeAfter(1));
    }

    function test_reductions_followTheSchedule() public view {
        uint256 e1 = schedule.cumulativeAfter(1);
        uint256[6] memory expected =
            [e1, e1 / 2, e1 * 3 / 10, e1 * 21 / 100, e1 * 168 / 1000, e1 * 168 / 1000 * 85 / 100];
        for (uint256 k = 1; k <= 6; ++k) {
            uint256 epochEmission = schedule.cumulativeAfter(k) - schedule.cumulativeAfter(k - 1);
            assertApproxEqAbs(epochEmission, expected[k - 1], 2, "epoch emission");
        }
        // Floor epochs keep reducing by 15%.
        for (uint256 k = 7; k <= 12; ++k) {
            uint256 previous = schedule.cumulativeAfter(k - 1) - schedule.cumulativeAfter(k - 2);
            uint256 current = schedule.cumulativeAfter(k) - schedule.cumulativeAfter(k - 1);
            assertApproxEqAbs(current, previous * 85 / 100, 2, "floor reduction");
        }
    }

    function test_cumulative_matchesTheWhitepaperTable() public view {
        uint256[9] memory epochs = [uint256(1), 2, 3, 4, 5, 6, 10, 20, 25];
        uint256[9] memory millions =
            [uint256(11.18e18), 16.77e18, 20.13e18, 22.48e18, 24.35e18, 25.95e18, 30.28e18, 34.07e18, 34.59e18];
        for (uint256 i; i < epochs.length; ++i) {
            assertApproxEqAbs(schedule.cumulativeAfter(epochs[i]), millions[i] * 1e6, 0.006e24, "table");
        }
    }

    function test_emission_accruesLinearlyWithinAnEpoch() public view {
        uint256 e1 = schedule.cumulativeAfter(1);
        assertEq(schedule.emittedUntil(START + EPOCH / 4), e1 / 4);
        assertEq(schedule.emittedUntil(START + EPOCH / 2), e1 / 2);

        uint256 e2 = schedule.cumulativeAfter(2) - e1;
        assertEq(schedule.emittedUntil(START + EPOCH + EPOCH / 2), e1 + e2 / 2);
    }

    function test_emitted_readsTheL1BlockPredeploy() public {
        l1.setNumber(uint64(START + EPOCH / 2));
        assertEq(schedule.currentL1Block(), START + EPOCH / 2);
        assertEq(schedule.emitted(), schedule.cumulativeAfter(1) / 2);
    }

    function test_schedule_neverReachesTheBucket() public view {
        uint256 total = schedule.cumulativeAfter(type(uint256).max);
        assertLt(total, schedule.BUCKET());
        assertApproxEqAbs(total, schedule.BUCKET(), 10);
        assertEq(
            schedule.emittedUntil(type(uint256).max), schedule.cumulativeAfter((type(uint256).max - START) / EPOCH)
        );
    }

    function test_cumulative_isMonotonicOverCenturies() public view {
        uint256 previous;
        for (uint256 k; k <= 800; ++k) {
            uint256 current = schedule.cumulativeAfter(k);
            assertGe(current, previous, "monotonic");
            previous = current;
        }
    }
}
