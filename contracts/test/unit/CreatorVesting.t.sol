// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CreatorVesting} from "../../src/distribution/CreatorVesting.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {Test} from "forge-std/Test.sol";

contract CreatorVestingTest is Test {
    uint256 internal constant ALLOCATION = 15_000_000e18;
    uint64 internal constant LAUNCH = 1_800_000_000;

    TenaxToken internal tenax;
    CreatorVesting internal vesting;
    address internal creator = makeAddr("creator");

    function setUp() public {
        vm.warp(LAUNCH);
        tenax = new TenaxToken(address(this));
        vesting = new CreatorVesting(creator, LAUNCH);
        tenax.transfer(address(vesting), ALLOCATION);
    }

    function _vested(uint256 timestamp) internal view returns (uint256) {
        return vesting.vestedAmount(address(tenax), uint64(timestamp));
    }

    function test_schedule_cliffThenLinearOverTwoYears() public view {
        assertEq(vesting.start(), LAUNCH + 365 days);
        assertEq(vesting.duration(), 730 days);
        assertEq(vesting.end(), LAUNCH + 1095 days);
        assertEq(vesting.owner(), creator);
    }

    function test_nothingVestsDuringTheFirstYear() public view {
        assertEq(_vested(LAUNCH), 0);
        assertEq(_vested(LAUNCH + 365 days - 1), 0);
        assertEq(_vested(LAUNCH + 365 days), 0, "no lump sum at the cliff");
    }

    function test_vestsLinearlyAfterTheCliff() public view {
        assertEq(_vested(LAUNCH + 365 days + 1 days), ALLOCATION / 730);
        assertEq(_vested(LAUNCH + 365 days + 365 days), ALLOCATION / 2);
        assertEq(_vested(LAUNCH + 1095 days), ALLOCATION);
        assertEq(_vested(LAUNCH + 2000 days), ALLOCATION);
    }

    function test_release_sendsVestedTokensToTheCreator() public {
        vesting.release(address(tenax));
        assertEq(tenax.balanceOf(creator), 0);

        vm.warp(LAUNCH + 730 days);
        vesting.release(address(tenax));
        assertEq(tenax.balanceOf(creator), ALLOCATION / 2);

        vm.warp(LAUNCH + 1095 days);
        vesting.release(address(tenax));
        assertEq(tenax.balanceOf(creator), ALLOCATION);
        assertEq(tenax.balanceOf(address(vesting)), 0);
    }

    function testFuzz_vestedIsMonotonicAndBounded(uint256 a, uint256 b) public view {
        a = bound(a, 0, type(uint64).max);
        b = bound(b, 0, type(uint64).max);
        (uint256 low, uint256 high) = a < b ? (a, b) : (b, a);
        assertLe(_vested(low), _vested(high));
        assertLe(_vested(high), ALLOCATION);
    }
}
