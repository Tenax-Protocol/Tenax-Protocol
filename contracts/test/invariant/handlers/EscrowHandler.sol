// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VotingEscrow} from "../../../src/escrow/VotingEscrow.sol";
import {TenaxToken} from "../../../src/token/TenaxToken.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives random sequences of every escrow operation with valid inputs, tracking expected outcomes.
/// Each operation looks for an actor for which it is valid, starting from the fuzzed seed, so that no call
/// is wasted; `withdraw` fast-forwards to the next expiry when no lock has expired yet.
contract EscrowHandler is Test {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant MAX_LOCK = 104 weeks;

    VotingEscrow public immutable escrow;
    TenaxToken public immutable token;
    address public immutable rewards;

    address[] public actors;
    uint256[] public snapshots;

    uint256 public ghostBurned;
    bool public ghostGrantedLeftEarly;
    mapping(string operation => uint256 count) public executed;

    constructor(VotingEscrow escrow_, TenaxToken token_, address rewards_, address[] memory actors_) {
        escrow = escrow_;
        token = token_;
        rewards = rewards_;
        actors = actors_;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function snapshotCount() external view returns (uint256) {
        return snapshots.length;
    }

    // --- operations ----------------------------------------------------------------

    function createLock(uint256 seed, uint256 amount, uint256 duration) external {
        (address actor, bool found) = _pick(seed, _canCreate);
        if (!found) return;
        // Lock at most half of the balance so later increases remain possible.
        uint256 lockAmount = bound(amount, 1, (token.balanceOf(actor) + 1) / 2);
        vm.prank(actor);
        escrow.createLock(lockAmount, vm.getBlockTimestamp() + bound(duration, 2 weeks, MAX_LOCK));
        _record("createLock");
    }

    function increaseAmount(uint256 seed, uint256 amount) external {
        (address actor, bool found) = _pick(seed, _canIncreaseAmount);
        if (!found) return;
        uint256 added = bound(amount, 1, token.balanceOf(actor)); // computed before the prank
        vm.prank(actor);
        escrow.increaseAmount(added);
        _record("increaseAmount");
    }

    function increaseUnlockTime(uint256 seed, uint256 extra) external {
        (address actor, bool found) = _pick(seed, _canExtend);
        if (!found) return;
        (,, uint256 end) = escrow.locked(actor);
        vm.prank(actor);
        escrow.increaseUnlockTime(bound(extra, end + WEEK, vm.getBlockTimestamp() + MAX_LOCK));
        _record("increaseUnlockTime");
    }

    function withdraw(uint256 seed) external {
        (address actor, bool found) = _pick(seed, _canWithdraw);
        if (!found) {
            uint256 nextExpiry = _nextExpiry();
            if (nextExpiry == type(uint256).max) return;
            vm.warp(nextExpiry);
            (actor, found) = _pick(seed, _canWithdraw);
            if (!found) return;
        }
        vm.prank(actor);
        escrow.withdraw();
        _record("withdraw");
    }

    function withdrawEarly(uint256 seed) external {
        (address actor, bool found) = _pick(seed, _canExitEarly);
        if (!found) return;
        (, uint256 granted, uint256 end) = escrow.locked(actor);

        uint256 supplyBefore = token.totalSupply();
        vm.prank(actor);
        escrow.withdrawEarly();
        ghostBurned += supplyBefore - token.totalSupply();

        (uint256 lockedAfter, uint256 grantedAfter, uint256 endAfter) = escrow.locked(actor);
        if (lockedAfter != granted || grantedAfter != granted || (granted != 0 && endAfter != end)) {
            ghostGrantedLeftEarly = true;
        }
        _record("withdrawEarly");
    }

    function createLockFor(uint256 seed, uint256 amount, uint256 duration) external {
        (address actor, bool found) = _pick(seed, _canReceiveGrant);
        if (!found) return;
        vm.prank(rewards);
        escrow.createLockFor(actor, bound(amount, 1, 100_000e18), bound(duration, 1 weeks, MAX_LOCK));
        _record("createLockFor");
    }

    function warp(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1, 26 weeks));
    }

    function checkpoint() external {
        escrow.checkpoint();
    }

    // --- predicates ------------------------------------------------------------------

    function _canCreate(address actor) internal view returns (bool) {
        (uint256 locked,,) = escrow.locked(actor);
        return locked == 0 && token.balanceOf(actor) > 0;
    }

    function _canIncreaseAmount(address actor) internal view returns (bool) {
        (uint256 locked,, uint256 end) = escrow.locked(actor);
        return locked != 0 && end > vm.getBlockTimestamp() && token.balanceOf(actor) > 0;
    }

    function _canExtend(address actor) internal view returns (bool) {
        (uint256 locked,, uint256 end) = escrow.locked(actor);
        return locked != 0 && end > vm.getBlockTimestamp() && end + WEEK <= vm.getBlockTimestamp() + MAX_LOCK;
    }

    function _canWithdraw(address actor) internal view returns (bool) {
        (uint256 locked,, uint256 end) = escrow.locked(actor);
        return locked != 0 && vm.getBlockTimestamp() >= end;
    }

    function _canExitEarly(address actor) internal view returns (bool) {
        (uint256 locked, uint256 granted, uint256 end) = escrow.locked(actor);
        return locked != 0 && end > vm.getBlockTimestamp() && locked > granted;
    }

    function _canReceiveGrant(address actor) internal view returns (bool) {
        (uint256 locked,, uint256 end) = escrow.locked(actor);
        return locked == 0 || end > vm.getBlockTimestamp();
    }

    // --- helpers -----------------------------------------------------------------------

    function _pick(uint256 seed, function(address) internal view returns (bool) valid)
        internal
        view
        returns (address actor, bool found)
    {
        uint256 start = bound(seed, 0, actors.length - 1);
        for (uint256 i; i < actors.length; ++i) {
            actor = actors[(start + i) % actors.length];
            if (valid(actor)) return (actor, true);
        }
        return (address(0), false);
    }

    function _nextExpiry() internal view returns (uint256 next) {
        next = type(uint256).max;
        for (uint256 i; i < actors.length; ++i) {
            (uint256 locked,, uint256 end) = escrow.locked(actors[i]);
            if (locked != 0 && end < next) next = end;
        }
    }

    function _record(string memory operation) internal {
        executed[operation]++;
        // Record a past timestamp so the invariant can check that history stays consistent.
        snapshots.push(vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1);
    }
}
