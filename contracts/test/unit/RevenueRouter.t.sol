// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IEthDepositor, RevenueRouter} from "../../src/revenue/RevenueRouter.sol";
import {MockEthDepositor} from "../mocks/MockEthDepositor.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {Test} from "forge-std/Test.sol";

contract RevenueRouterTest is Test {
    MockWETH internal weth;
    MockEthDepositor internal seasonRewards;
    MockEthDepositor internal feeDistributor;
    RevenueRouter internal router;
    address internal treasury = makeAddr("treasury");
    address internal governance = makeAddr("governance");

    function setUp() public {
        weth = new MockWETH();
        seasonRewards = new MockEthDepositor(weth);
        feeDistributor = new MockEthDepositor(weth);
        router = new RevenueRouter(
            IWETH(address(weth)),
            IEthDepositor(address(seasonRewards)),
            IEthDepositor(address(feeDistributor)),
            treasury,
            governance
        );
    }

    function _fund(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(router), amount);
    }

    function test_initialSplit_is40_40_20() public view {
        assertEq(router.forecastersBps(), 4000);
        assertEq(router.holdersBps(), 4000);
        assertEq(router.treasuryBps(), 2000);
    }

    function test_distribute_splitsTheWholeBalance() public {
        _fund(1 ether);
        router.distribute();
        assertEq(seasonRewards.received(), 0.4 ether);
        assertEq(feeDistributor.received(), 0.4 ether);
        assertEq(weth.balanceOf(treasury), 0.2 ether);
        assertEq(weth.balanceOf(address(router)), 0);
    }

    function test_distribute_sendsRoundingDustToTheTreasury() public {
        _fund(7);
        router.distribute();
        assertEq(seasonRewards.received(), 2);
        assertEq(feeDistributor.received(), 2);
        assertEq(weth.balanceOf(treasury), 3);
    }

    function test_distribute_skipsEmptyShares() public {
        _fund(1);
        router.distribute();
        assertEq(seasonRewards.received(), 0);
        assertEq(feeDistributor.received(), 0);
        assertEq(weth.balanceOf(treasury), 1);
    }

    function test_RevertWhen_nothingToDistribute() public {
        vm.expectRevert(RevenueRouter.NothingToDistribute.selector);
        router.distribute();
    }

    function test_setShares_withinBounds() public {
        vm.prank(governance);
        router.setShares(5500, 2500, 2000);
        _fund(1 ether);
        router.distribute();
        assertEq(seasonRewards.received(), 0.55 ether);
        assertEq(feeDistributor.received(), 0.25 ether);
        assertEq(weth.balanceOf(treasury), 0.2 ether);
    }

    function test_RevertWhen_sharesAreOutOfBounds() public {
        uint256[3][6] memory invalid = [
            [uint256(2400), 5500, 2100], // forecasters too low
            [uint256(5600), 2500, 1900], // forecasters too high
            [uint256(5500), 2400, 2100], // holders too low
            [uint256(4000), 5600, 400], // holders too high, treasury too low
            [uint256(3500), 3400, 3100], // treasury too high
            [uint256(4000), 4000, 2100] // does not sum to 100%
        ];
        vm.startPrank(governance);
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(RevenueRouter.InvalidShares.selector);
            router.setShares(invalid[i][0], invalid[i][1], invalid[i][2]);
        }
        vm.stopPrank();
    }

    function test_RevertWhen_notGovernance() public {
        vm.expectRevert(RevenueRouter.NotGovernance.selector);
        router.setShares(4000, 4000, 2000);
    }

    function test_RevertWhen_constructorArgumentsAreInvalid() public {
        IWETH w = IWETH(address(weth));
        IEthDepositor sr = IEthDepositor(address(seasonRewards));
        IEthDepositor fd = IEthDepositor(address(feeDistributor));
        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        new RevenueRouter(IWETH(address(0)), sr, fd, treasury, governance);
        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        new RevenueRouter(w, IEthDepositor(address(0)), fd, treasury, governance);
        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        new RevenueRouter(w, sr, IEthDepositor(address(0)), treasury, governance);
        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        new RevenueRouter(w, sr, fd, address(0), governance);
        vm.expectRevert(RevenueRouter.ZeroAddress.selector);
        new RevenueRouter(w, sr, fd, treasury, address(0));
    }

    function testFuzz_distribute_conservesRevenue(uint256 amount, uint256 forecasters, uint256 holders) public {
        amount = bound(amount, 1, 1_000_000 ether);
        forecasters = bound(forecasters, 2500, 5500);
        holders = bound(holders, 2500, 5500);
        vm.assume(forecasters + holders >= 7000 && forecasters + holders <= 9500);
        vm.prank(governance);
        router.setShares(forecasters, holders, 10_000 - forecasters - holders);

        _fund(amount);
        router.distribute();
        assertEq(seasonRewards.received() + feeDistributor.received() + weth.balanceOf(treasury), amount);
        assertEq(seasonRewards.received(), amount * forecasters / 10_000);
        assertEq(feeDistributor.received(), amount * holders / 10_000);
    }
}
