// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {FeeDistributor} from "../../src/revenue/FeeDistributor.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {Test} from "forge-std/Test.sol";

contract FeeDistributorTest is Test {
    uint256 internal constant WEEK = 1 weeks;
    uint256 internal constant START = 1_800_000_000;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    MockWETH internal weth;
    FeeDistributor internal distributor;
    uint256 internal week0;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal router = makeAddr("router");

    function setUp() public {
        vm.warp(START);
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        weth = new MockWETH();
        distributor = new FeeDistributor(IWETH(address(weth)), escrow);
        week0 = START / WEEK * WEEK;

        vm.deal(router, 1_000_000 ether);
        vm.startPrank(router);
        weth.deposit{value: 1_000_000 ether}();
        weth.approve(address(distributor), type(uint256).max);
        vm.stopPrank();
    }

    function _lock(address user, uint256 amount, uint256 duration) internal {
        tenax.transfer(user, amount);
        vm.startPrank(user);
        tenax.approve(address(escrow), amount);
        escrow.createLock(amount, vm.getBlockTimestamp() + duration);
        vm.stopPrank();
    }

    function _deposit(uint256 amount) internal {
        vm.prank(router);
        distributor.depositEth(amount);
    }

    function _claim(address holder) internal returns (uint256) {
        return distributor.claim(holder);
    }

    // --- deposits and weeks ------------------------------------------------------

    function test_depositEth_creditsTheCurrentWeek() public {
        _deposit(1 ether);
        vm.warp(week0 + WEEK + 1);
        _deposit(2 ether);
        assertEq(distributor.tokensPerWeek(week0), 0, "rolled over: no veTENAX at the start of week 0");
        assertEq(distributor.tokensPerWeek(week0 + WEEK), 3 ether);
        assertEq(distributor.startWeek(), week0);
        assertEq(weth.balanceOf(address(distributor)), 3 ether);
    }

    function test_claim_paysNothingBeforeTheWeekEnds() public {
        _lock(alice, 1000e18, 52 weeks);
        vm.warp(week0 + WEEK);
        _deposit(1 ether);
        vm.warp(week0 + 2 * WEEK - 1);
        assertEq(_claim(alice), 0);
        assertEq(distributor.weekCursor(), week0 + WEEK);
    }

    function test_claim_paysProRataByBalanceAtTheWeekStart() public {
        _lock(alice, 3000e18, 104 weeks);
        _lock(bob, 1000e18, 52 weeks);
        uint256 week1 = week0 + WEEK;
        vm.warp(week1 + 1 days);
        _deposit(1 ether);
        _lock(carol, 50_000e18, 104 weeks); // locked during the week: no share of it

        vm.warp(week1 + WEEK);
        uint256 total = escrow.totalSupplyAt(week1);
        uint256 aliceShare = 1 ether * escrow.balanceOfAt(alice, week1) / total;
        uint256 bobShare = 1 ether * escrow.balanceOfAt(bob, week1) / total;
        assertEq(distributor.claimable(alice), 0, "week not final until someone checkpoints");

        distributor.checkpoint();
        assertEq(distributor.veSupply(week1), total);
        assertEq(distributor.claimable(alice), aliceShare);
        assertEq(_claim(alice), aliceShare);
        assertEq(_claim(bob), bobShare);
        assertEq(_claim(carol), 0);
        assertEq(weth.balanceOf(alice), aliceShare);
        assertEq(weth.balanceOf(bob), bobShare);
        assertGt(aliceShare, bobShare * 5, "longer and larger lock");
        assertApproxEqAbs(aliceShare + bobShare, 1 ether, 2);
    }

    function test_claim_isIdempotent() public {
        _lock(alice, 1000e18, 52 weeks);
        vm.warp(week0 + WEEK);
        _deposit(1 ether);
        vm.warp(week0 + 2 * WEEK);
        assertEq(_claim(alice), 1 ether);
        assertEq(_claim(alice), 0);
        assertEq(distributor.holderWeekCursor(alice), week0 + 2 * WEEK);
    }

    function test_weekWithoutVe_rollsOverToTheNextWeek() public {
        _deposit(1 ether); // week 0 starts with no veTENAX
        _lock(alice, 1000e18, 52 weeks);
        vm.warp(week0 + WEEK + 1 days);
        _deposit(0.5 ether);

        vm.warp(week0 + 2 * WEEK);
        distributor.checkpoint();
        assertEq(distributor.tokensPerWeek(week0), 0);
        assertEq(distributor.tokensPerWeek(week0 + WEEK), 1.5 ether);
        assertEq(_claim(alice), 1.5 ether);
    }

    function test_claim_coversAtMost52WeeksPerCall() public {
        _lock(alice, 1000e18, 104 weeks);
        vm.warp(week0 + 60 * WEEK + 1);
        _deposit(1 ether); // finalizes the first 52 weeks
        assertEq(distributor.weekCursor(), week0 + 52 * WEEK);

        vm.warp(week0 + 61 * WEEK);
        distributor.checkpoint();
        assertEq(distributor.weekCursor(), week0 + 61 * WEEK);

        assertEq(_claim(alice), 0);
        assertEq(distributor.holderWeekCursor(alice), week0 + 53 * WEEK);
        assertEq(_claim(alice), 1 ether);
    }

    function test_claimAsEth_paysTheCallerInNativeEth() public {
        _lock(alice, 1000e18, 52 weeks);
        vm.warp(week0 + WEEK);
        _deposit(1 ether);
        vm.warp(week0 + 2 * WEEK);
        vm.prank(alice);
        uint256 paid = distributor.claimAsEth();
        assertEq(paid, 1 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(weth.balanceOf(alice), 0);
    }

    function test_claim_forAnotherHolderPaysTheHolder() public {
        _lock(alice, 1000e18, 52 weeks);
        vm.warp(week0 + WEEK);
        _deposit(1 ether);
        vm.warp(week0 + 2 * WEEK);
        vm.prank(bob);
        distributor.claim(alice);
        assertEq(weth.balanceOf(alice), 1 ether);
        assertEq(weth.balanceOf(bob), 0);
    }

    function test_claim_locksOlderThanTheDistributorStartAtItsFirstWeek() public {
        _lock(alice, 1000e18, 52 weeks);
        vm.warp(START + 10 weeks);
        FeeDistributor late = new FeeDistributor(IWETH(address(weth)), escrow);
        uint256 lateWeek = late.startWeek();
        vm.startPrank(router);
        weth.approve(address(late), 1 ether);
        late.depositEth(1 ether); // the distributor's first week, where alice already holds veTENAX
        vm.stopPrank();

        vm.warp(lateWeek + WEEK);
        assertEq(late.claim(alice), 1 ether);
        assertEq(late.holderWeekCursor(alice), lateWeek + WEEK);
    }

    function test_claim_withoutALockPaysNothing() public {
        vm.warp(week0 + 3 * WEEK);
        assertEq(_claim(carol), 0);
        assertEq(distributor.holderWeekCursor(carol), 0);
    }

    function test_RevertWhen_depositIsZero() public {
        vm.expectRevert(FeeDistributor.ZeroAmount.selector);
        distributor.depositEth(0);
    }

    function test_RevertWhen_sendingEthDirectly() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory reason) = address(distributor).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(reason), FeeDistributor.UnexpectedEth.selector);
    }

    function test_RevertWhen_constructorArgumentsAreInvalid() public {
        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        new FeeDistributor(IWETH(address(0)), escrow);
        vm.expectRevert(FeeDistributor.ZeroAddress.selector);
        new FeeDistributor(IWETH(address(weth)), VotingEscrow(address(0)));
    }

    function testFuzz_sharesSumToTheDeposit(uint256 a, uint256 b, uint256 da, uint256 db, uint256 amount) public {
        a = bound(a, 1e18, 10_000_000e18);
        b = bound(b, 1e18, 10_000_000e18);
        da = bound(da, 2 weeks, 104 weeks);
        db = bound(db, 2 weeks, 104 weeks);
        amount = bound(amount, 1, 1000 ether);
        _lock(alice, a, da);
        _lock(bob, b, db);
        vm.warp(week0 + WEEK);
        _deposit(amount);
        vm.warp(week0 + 2 * WEEK);

        uint256 paid = _claim(alice) + _claim(bob);
        assertLe(paid, amount);
        assertGe(paid + 2, amount);
    }
}
