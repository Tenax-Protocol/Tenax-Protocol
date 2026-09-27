// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowMath} from "../../src/escrow/EscrowMath.sol";
import {EscrowTestBase} from "../utils/EscrowTestBase.sol";

/// @dev Differential tests: the escrow must match the closed-form reference formulas.
contract VotingEscrowFuzzTest is EscrowTestBase {
    function testFuzz_balanceMatchesReference(uint256 amount, uint256 duration, uint256 elapsed) public {
        amount = bound(amount, 1, USER_BALANCE);
        duration = bound(duration, 2 weeks, MAX_LOCK);
        uint256 end = _lock(alice, amount, duration);

        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, MAX_LOCK + 10 weeks));

        assertEq(escrow.balanceOf(alice), _expectedBalance(amount, end, vm.getBlockTimestamp()));
        assertEq(escrow.totalSupply(), escrow.balanceOf(alice));
    }

    function testFuzz_totalSupplyEqualsSumOfStaggeredLocks(
        uint256[4] memory amounts,
        uint256[4] memory durations,
        uint256[4] memory gaps,
        uint256 elapsed
    ) public {
        address[4] memory users = [alice, bob, makeAddr("carol"), makeAddr("dave")];
        _fund(users[2], USER_BALANCE);
        _fund(users[3], USER_BALANCE);
        uint256[4] memory ends;

        for (uint256 i; i < 4; ++i) {
            vm.warp(vm.getBlockTimestamp() + bound(gaps[i], 0, 20 weeks));
            amounts[i] = bound(amounts[i], 1, USER_BALANCE);
            ends[i] = _lock(users[i], amounts[i], bound(durations[i], 2 weeks, MAX_LOCK));
        }
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, MAX_LOCK));

        uint256 sum;
        for (uint256 i; i < 4; ++i) {
            uint256 balance = escrow.balanceOf(users[i]);
            assertEq(balance, _expectedBalance(amounts[i], ends[i], vm.getBlockTimestamp()));
            sum += balance;
        }
        assertEq(escrow.totalSupply(), sum);
    }

    function testFuzz_earlyExitMatchesReference(uint256 amount, uint256 duration, uint256 elapsed) public {
        amount = bound(amount, 1, USER_BALANCE);
        uint256 end = _lock(alice, amount, bound(duration, 2 weeks, MAX_LOCK));
        vm.warp(vm.getBlockTimestamp() + bound(elapsed, 0, end - vm.getBlockTimestamp() - 1));

        uint256 timeLeft = end - vm.getBlockTimestamp();
        uint256 capped = timeLeft < MAX_LOCK / 2 ? timeLeft : MAX_LOCK / 2;
        uint256 expectedPenalty = (amount * capped + MAX_LOCK - 1) / MAX_LOCK; // rounded up
        uint256 tokenSupplyBefore = token.totalSupply();

        vm.prank(alice);
        escrow.withdrawEarly();

        assertEq(token.balanceOf(alice), USER_BALANCE - expectedPenalty);
        assertEq(token.totalSupply(), tokenSupplyBefore - expectedPenalty);
        assertLe(expectedPenalty * 2, amount + 1, "penalty never exceeds half");
        assertEq(escrow.totalSupply(), 0);
    }

    function testFuzz_pastBalancesNeverChange(uint256 amount, uint256 probeDelay, uint256 laterDelay) public {
        amount = bound(amount, 1e18, USER_BALANCE / 2);
        _lock(alice, amount, 60 weeks);
        vm.warp(vm.getBlockTimestamp() + bound(probeDelay, 1, 30 weeks));
        uint256 probe = vm.getBlockTimestamp();
        uint256 aliceAtProbe = escrow.balanceOf(alice);
        uint256 supplyAtProbe = escrow.totalSupply();

        vm.warp(vm.getBlockTimestamp() + bound(laterDelay, 1, 20 weeks));
        vm.prank(alice);
        escrow.increaseAmount(amount);
        _lock(bob, amount, 30 weeks);
        _lockFor(alice, amount, 80 weeks);

        assertEq(escrow.balanceOfAt(alice, probe), aliceAtProbe);
        assertEq(escrow.totalSupplyAt(probe), supplyAtProbe);
        assertEq(escrow.getPastVotes(alice, probe), aliceAtProbe);
    }

    function testFuzz_createLockForExtendsToRequiredEnd(uint256 existingDuration, uint256 grantDuration) public {
        uint256 existingEnd = _lock(alice, 1000e18, bound(existingDuration, 2 weeks, MAX_LOCK));
        grantDuration = bound(grantDuration, 1 weeks, MAX_LOCK);
        uint256 requiredEnd = EscrowMath.roundDownToWeek(vm.getBlockTimestamp() + grantDuration);

        _lockFor(alice, 400e18, grantDuration);

        (uint256 amount, uint256 granted, uint256 end) = _lockOf(alice);
        assertEq(amount, 1400e18);
        assertEq(granted, 400e18);
        assertEq(end, existingEnd > requiredEnd ? existingEnd : requiredEnd);
        assertEq(escrow.totalSupply(), escrow.balanceOf(alice));
    }
}
