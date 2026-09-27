// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowMath} from "../../src/escrow/EscrowMath.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {EscrowTestBase} from "../utils/EscrowTestBase.sol";

contract VotingEscrowTest is EscrowTestBase {
    // --- setup -----------------------------------------------------------------

    function test_metadataAndClock() public view {
        assertEq(escrow.name(), "Vote-escrowed TENAX");
        assertEq(escrow.symbol(), "veTENAX");
        assertEq(escrow.decimals(), 18);
        assertEq(escrow.clock(), vm.getBlockTimestamp());
        assertEq(escrow.CLOCK_MODE(), "mode=timestamp");
        assertEq(address(escrow.token()), address(token));
    }

    function test_RevertWhen_constructedWithZeroToken() public {
        vm.expectRevert(VotingEscrow.ZeroAddress.selector);
        new VotingEscrow(IBurnableERC20(address(0)));
    }

    function test_initializeDistributors_setsListOnce() public view {
        assertTrue(escrow.distributorsInitialized());
        assertTrue(escrow.isDistributor(rewards));
        assertFalse(escrow.isDistributor(alice));
    }

    function test_RevertWhen_distributorsInitializedTwice() public {
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectRevert(VotingEscrow.DistributorsAlreadyInitialized.selector);
        escrow.initializeDistributors(list);
    }

    function test_RevertWhen_distributorsInitializedByOther() public {
        VotingEscrow fresh = new VotingEscrow(IBurnableERC20(address(token)));
        address[] memory list = new address[](1);
        list[0] = alice;
        vm.expectRevert(VotingEscrow.NotInitializer.selector);
        vm.prank(alice);
        fresh.initializeDistributors(list);
    }

    function test_RevertWhen_distributorIsZeroAddress() public {
        VotingEscrow fresh = new VotingEscrow(IBurnableERC20(address(token)));
        address[] memory list = new address[](1);
        vm.expectRevert(VotingEscrow.ZeroAddress.selector);
        fresh.initializeDistributors(list);
    }

    // --- createLock ------------------------------------------------------------

    function test_createLock_locksTokensAndRoundsEndDown() public {
        uint256 end = _lock(alice, 1000e18, 52 weeks);

        (uint256 amount, uint256 granted, uint256 lockEnd) = _lockOf(alice);
        assertEq(amount, 1000e18);
        assertEq(granted, 0);
        assertEq(lockEnd, end);
        assertEq(lockEnd % WEEK, 0);
        assertLt(lockEnd, vm.getBlockTimestamp() + 52 weeks);
        assertEq(escrow.supply(), 1000e18);
        assertEq(token.balanceOf(address(escrow)), 1000e18);
        assertEq(escrow.balanceOf(alice), _expectedBalance(1000e18, end, vm.getBlockTimestamp()));
    }

    function test_createLock_maxLockGivesAlmostFullWeight() public {
        _lock(alice, 1000e18, MAX_LOCK);
        // Rounding down to the week costs at most one week of weight.
        assertGe(escrow.balanceOf(alice), 1000e18 * (MAX_LOCK - WEEK) / MAX_LOCK - 1e18);
        assertLe(escrow.balanceOf(alice), 1000e18);
    }

    function test_RevertWhen_createLockWithZeroAmount() public {
        vm.expectRevert(VotingEscrow.ZeroAmount.selector);
        vm.prank(alice);
        escrow.createLock(0, vm.getBlockTimestamp() + 10 weeks);
    }

    function test_RevertWhen_createLockTwice() public {
        _lock(alice, 1000e18, 10 weeks);
        vm.expectRevert(VotingEscrow.LockAlreadyExists.selector);
        vm.prank(alice);
        escrow.createLock(1000e18, vm.getBlockTimestamp() + 10 weeks);
    }

    function test_RevertWhen_createLockShorterThanOneWeek() public {
        uint256 unlockTime = vm.getBlockTimestamp() + 7 days; // rounds down to less than a week from now
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.UnlockTimeTooSoon.selector, unlockTime));
        vm.prank(alice);
        escrow.createLock(1000e18, unlockTime);
    }

    function test_RevertWhen_createLockLongerThanMax() public {
        uint256 unlockTime = vm.getBlockTimestamp() + MAX_LOCK + WEEK;
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.UnlockTimeTooLate.selector, unlockTime));
        vm.prank(alice);
        escrow.createLock(1000e18, unlockTime);
    }

    // --- decay -----------------------------------------------------------------

    function test_balance_decaysLinearlyToZero() public {
        uint256 end = _lock(alice, 1000e18, 52 weeks);
        uint256 initial = escrow.balanceOf(alice);

        vm.warp(vm.getBlockTimestamp() + 10 weeks);
        assertEq(escrow.balanceOf(alice), _expectedBalance(1000e18, end, vm.getBlockTimestamp()));
        assertLt(escrow.balanceOf(alice), initial);

        vm.warp(end);
        assertEq(escrow.balanceOf(alice), 0);
        assertEq(escrow.totalSupply(), 0);
    }

    function test_totalSupply_equalsSumOfBalances() public {
        _lock(alice, 1000e18, 52 weeks);
        _lock(bob, 3000e18, 20 weeks);
        for (uint256 i; i < 60; ++i) {
            assertEq(escrow.totalSupply(), escrow.balanceOf(alice) + escrow.balanceOf(bob));
            vm.warp(vm.getBlockTimestamp() + 1 weeks + 3 hours);
        }
    }

    // --- increaseAmount / increaseUnlockTime --------------------------------------

    function test_increaseAmount_addsToVoluntaryPortion() public {
        uint256 end = _lock(alice, 1000e18, 52 weeks);
        vm.prank(alice);
        escrow.increaseAmount(500e18);

        (uint256 amount, uint256 granted, uint256 lockEnd) = _lockOf(alice);
        assertEq(amount, 1500e18);
        assertEq(granted, 0);
        assertEq(lockEnd, end);
        assertEq(escrow.balanceOf(alice), _expectedBalance(1500e18, end, vm.getBlockTimestamp()));
    }

    function test_RevertWhen_increaseAmountWithZero() public {
        _lock(alice, 1000e18, 10 weeks);
        vm.expectRevert(VotingEscrow.ZeroAmount.selector);
        vm.prank(alice);
        escrow.increaseAmount(0);
    }

    function test_totalSupplyAt_isZeroBeforeDeployment() public {
        _lock(alice, 1000e18, 10 weeks);
        assertEq(escrow.totalSupplyAt(START - 1), 0);
        assertEq(escrow.balanceOfAt(alice, START - 1), 0);
    }

    function test_RevertWhen_increaseAmountWithoutLock() public {
        vm.expectRevert(VotingEscrow.NoLock.selector);
        vm.prank(alice);
        escrow.increaseAmount(1e18);
    }

    function test_RevertWhen_increaseAmountAfterExpiry() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.warp(end);
        vm.expectRevert(VotingEscrow.LockExpired.selector);
        vm.prank(alice);
        escrow.increaseAmount(1e18);
    }

    function test_increaseUnlockTime_extendsLock() public {
        _lock(alice, 1000e18, 10 weeks);
        uint256 newEnd = EscrowMath.roundDownToWeek(vm.getBlockTimestamp() + 60 weeks);
        vm.prank(alice);
        escrow.increaseUnlockTime(vm.getBlockTimestamp() + 60 weeks);

        (,, uint256 lockEnd) = _lockOf(alice);
        assertEq(lockEnd, newEnd);
        assertEq(escrow.balanceOf(alice), _expectedBalance(1000e18, newEnd, vm.getBlockTimestamp()));
        assertEq(escrow.totalSupply(), escrow.balanceOf(alice));
    }

    function test_RevertWhen_increaseUnlockTimeNotLater() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.UnlockTimeNotIncreased.selector, end));
        vm.prank(alice);
        escrow.increaseUnlockTime(end);
    }

    function test_RevertWhen_increaseUnlockTimeBeyondMax() public {
        _lock(alice, 1000e18, 10 weeks);
        uint256 unlockTime = vm.getBlockTimestamp() + MAX_LOCK + WEEK;
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.UnlockTimeTooLate.selector, unlockTime));
        vm.prank(alice);
        escrow.increaseUnlockTime(unlockTime);
    }

    function test_RevertWhen_increaseUnlockTimeWithoutLock() public {
        vm.expectRevert(VotingEscrow.NoLock.selector);
        vm.prank(alice);
        escrow.increaseUnlockTime(vm.getBlockTimestamp() + 10 weeks);
    }

    function test_RevertWhen_increaseUnlockTimeAfterExpiry() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.warp(end + 1);
        vm.expectRevert(VotingEscrow.LockExpired.selector);
        vm.prank(alice);
        escrow.increaseUnlockTime(vm.getBlockTimestamp() + 10 weeks);
    }

    // --- withdraw --------------------------------------------------------------

    function test_withdraw_returnsEverythingAfterExpiry() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.warp(end);
        vm.prank(alice);
        escrow.withdraw();

        assertEq(token.balanceOf(alice), USER_BALANCE);
        assertEq(escrow.supply(), 0);
        (uint256 amount,, uint256 lockEnd) = _lockOf(alice);
        assertEq(amount, 0);
        assertEq(lockEnd, 0);
    }

    function test_withdraw_allowsANewLockAfterwards() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.warp(end);
        vm.prank(alice);
        escrow.withdraw();
        _lock(alice, 200e18, 20 weeks);
        assertGt(escrow.balanceOf(alice), 0);
    }

    function test_RevertWhen_withdrawBeforeExpiry() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.LockNotExpired.selector, end));
        vm.prank(alice);
        escrow.withdraw();
    }

    function test_RevertWhen_withdrawWithoutLock() public {
        vm.expectRevert(VotingEscrow.NoLock.selector);
        vm.prank(alice);
        escrow.withdraw();
    }

    // --- withdrawEarly ---------------------------------------------------------

    function test_withdrawEarly_penaltyIsCappedAtHalf() public {
        _lock(alice, 1000e18, MAX_LOCK);
        uint256 supplyBefore = token.totalSupply();

        vm.prank(alice);
        escrow.withdrawEarly();

        assertEq(token.balanceOf(alice), USER_BALANCE - 500e18);
        assertEq(token.totalSupply(), supplyBefore - 500e18, "penalty must be burned");
        assertEq(escrow.supply(), 0);
        assertEq(escrow.balanceOf(alice), 0);
        (uint256 amount,, uint256 end) = _lockOf(alice);
        assertEq(amount, 0);
        assertEq(end, 0);
    }

    function test_withdrawEarly_penaltyIsProportionalToTimeLeft() public {
        uint256 end = _lock(alice, 1040e18, 30 weeks);
        vm.warp(end - 26 weeks); // exactly 26 weeks left: 25% penalty

        vm.prank(alice);
        escrow.withdrawEarly();

        assertEq(token.balanceOf(alice), USER_BALANCE - 260e18);
    }

    function test_withdrawEarly_keepsGrantedPortionLocked() public {
        uint256 end = _lock(alice, 1000e18, 52 weeks);
        _lockFor(alice, 400e18, 26 weeks); // shorter than the existing lock: end stays

        vm.warp(vm.getBlockTimestamp() + 2 weeks);
        uint256 timeLeft = end - vm.getBlockTimestamp();
        uint256 penalty = EscrowMath.earlyExitPenalty(1000e18, timeLeft);

        vm.prank(alice);
        escrow.withdrawEarly();

        assertEq(token.balanceOf(alice), USER_BALANCE - penalty);
        (uint256 amount, uint256 granted, uint256 lockEnd) = _lockOf(alice);
        assertEq(amount, 400e18);
        assertEq(granted, 400e18);
        assertEq(lockEnd, end);
        assertEq(escrow.supply(), 400e18);
        assertEq(escrow.balanceOf(alice), _expectedBalance(400e18, end, vm.getBlockTimestamp()));
        assertEq(escrow.totalSupply(), escrow.balanceOf(alice));
    }

    function test_RevertWhen_withdrawEarlyWithOnlyGrantedTokens() public {
        _lockFor(alice, 400e18, 26 weeks);
        vm.expectRevert(VotingEscrow.NoVoluntaryBalance.selector);
        vm.prank(alice);
        escrow.withdrawEarly();
    }

    function test_RevertWhen_withdrawEarlyAfterExpiry() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.warp(end);
        vm.expectRevert(VotingEscrow.LockExpired.selector);
        vm.prank(alice);
        escrow.withdrawEarly();
    }

    function test_RevertWhen_withdrawEarlyWithoutLock() public {
        vm.expectRevert(VotingEscrow.NoLock.selector);
        vm.prank(alice);
        escrow.withdrawEarly();
    }

    // --- createLockFor ---------------------------------------------------------

    function test_createLockFor_createsGrantedLockPaidByDistributor() public {
        uint256 rewardsBefore = token.balanceOf(rewards);
        _lockFor(alice, 400e18, 52 weeks);

        (uint256 amount, uint256 granted, uint256 end) = _lockOf(alice);
        assertEq(amount, 400e18);
        assertEq(granted, 400e18);
        assertEq(end, EscrowMath.roundDownToWeek(vm.getBlockTimestamp() + 52 weeks));
        assertEq(token.balanceOf(rewards), rewardsBefore - 400e18);
        assertEq(token.balanceOf(alice), USER_BALANCE, "the beneficiary pays nothing");
    }

    function test_createLockFor_extendsShorterLock() public {
        _lock(alice, 1000e18, 10 weeks);
        _lockFor(alice, 400e18, 52 weeks);

        (uint256 amount, uint256 granted, uint256 end) = _lockOf(alice);
        assertEq(amount, 1400e18);
        assertEq(granted, 400e18);
        assertEq(end, EscrowMath.roundDownToWeek(vm.getBlockTimestamp() + 52 weeks));
        assertEq(escrow.totalSupply(), escrow.balanceOf(alice));
    }

    function test_createLockFor_neverShortensLongerLock() public {
        uint256 end = _lock(alice, 1000e18, 80 weeks);
        _lockFor(alice, 400e18, 52 weeks);

        (,, uint256 lockEnd) = _lockOf(alice);
        assertEq(lockEnd, end);
    }

    function test_RevertWhen_createLockForByNonDistributor() public {
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.NotDistributor.selector, alice));
        vm.prank(alice);
        escrow.createLockFor(bob, 1e18, 52 weeks);
    }

    function test_RevertWhen_createLockForExpiredLock() public {
        uint256 end = _lock(alice, 1000e18, 10 weeks);
        vm.warp(end);
        vm.expectRevert(VotingEscrow.LockExpired.selector);
        vm.prank(rewards);
        escrow.createLockFor(alice, 1e18, 52 weeks);
    }

    function test_RevertWhen_createLockForInvalidDuration() public {
        vm.startPrank(rewards);
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.InvalidLockDuration.selector, 6 days));
        escrow.createLockFor(alice, 1e18, 6 days);
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.InvalidLockDuration.selector, MAX_LOCK + 1));
        escrow.createLockFor(alice, 1e18, MAX_LOCK + 1);
        vm.stopPrank();
    }

    function test_RevertWhen_createLockForZeroBeneficiaryOrAmount() public {
        vm.startPrank(rewards);
        vm.expectRevert(VotingEscrow.ZeroAddress.selector);
        escrow.createLockFor(address(0), 1e18, 52 weeks);
        vm.expectRevert(VotingEscrow.ZeroAmount.selector);
        escrow.createLockFor(alice, 0, 52 weeks);
        vm.stopPrank();
    }

    // --- history and IVotes ----------------------------------------------------

    function test_history_pastBalancesDoNotChange() public {
        uint256 end = _lock(alice, 1000e18, 52 weeks);
        uint256 t1 = vm.getBlockTimestamp();
        uint256 balanceAtT1 = escrow.balanceOf(alice);

        vm.warp(vm.getBlockTimestamp() + 5 weeks);
        vm.prank(alice);
        escrow.increaseAmount(2000e18);
        vm.warp(vm.getBlockTimestamp() + 5 weeks);

        assertEq(escrow.balanceOfAt(alice, t1), balanceAtT1);
        assertEq(escrow.balanceOfAt(alice, t1 - 1), 0, "no balance before the lock");
        assertEq(escrow.totalSupplyAt(t1), balanceAtT1);
        assertEq(escrow.balanceOf(alice), _expectedBalance(3000e18, end, vm.getBlockTimestamp()));
    }

    function test_getPastVotes_matchesHistory() public {
        _lock(alice, 1000e18, 52 weeks);
        uint256 t1 = vm.getBlockTimestamp();
        vm.warp(vm.getBlockTimestamp() + 3 weeks);

        assertEq(escrow.getPastVotes(alice, t1), escrow.balanceOfAt(alice, t1));
        assertEq(escrow.getPastTotalSupply(t1), escrow.totalSupplyAt(t1));
        assertEq(escrow.getVotes(alice), escrow.balanceOf(alice));
    }

    function test_RevertWhen_lookingUpTheFuture() public {
        uint48 now_ = uint48(vm.getBlockTimestamp());
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.ERC5805FutureLookup.selector, now_, now_));
        escrow.getPastVotes(alice, now_);
        vm.expectRevert(abi.encodeWithSelector(VotingEscrow.ERC5805FutureLookup.selector, now_, now_));
        escrow.getPastTotalSupply(now_);
    }

    function test_delegation_isDisabled() public {
        assertEq(escrow.delegates(alice), alice);
        vm.expectRevert(VotingEscrow.DelegationDisabled.selector);
        escrow.delegate(bob);
        vm.expectRevert(VotingEscrow.DelegationDisabled.selector);
        escrow.delegateBySig(bob, 0, 0, 0, bytes32(0), bytes32(0));
    }

    // --- long inactivity ---------------------------------------------------------

    function test_checkpoint_catchesUpAfterLongInactivity() public {
        _lock(alice, 1000e18, 10 weeks);
        vm.warp(vm.getBlockTimestamp() + 300 weeks);

        vm.expectRevert(VotingEscrow.CheckpointRequired.selector);
        vm.prank(bob);
        escrow.createLock(1e18, vm.getBlockTimestamp() + 10 weeks);

        escrow.checkpoint(); // advances 255 weeks
        escrow.checkpoint(); // reaches the present
        _lock(bob, 1e18, 10 weeks);
        assertEq(escrow.totalSupply(), escrow.balanceOf(bob));
    }
}
