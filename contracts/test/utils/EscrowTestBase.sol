// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowMath} from "../../src/escrow/EscrowMath.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Shared setup for vote escrow tests: a token, an escrow with one authorized distributor, funded users.
abstract contract EscrowTestBase is Test {
    uint256 internal constant WEEK = 7 days;
    uint256 internal constant MAX_LOCK = 104 weeks;
    uint256 internal constant USER_BALANCE = 1_000_000e18;
    /// @dev A Wednesday at noon, so week rounding is visible in tests.
    uint256 internal constant START = 1_800_100_800;

    TenaxToken internal token;
    VotingEscrow internal escrow;
    address internal treasury = makeAddr("treasury");
    address internal rewards = makeAddr("rewards");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual {
        vm.warp(START);
        token = new TenaxToken(treasury);
        escrow = new VotingEscrow(IBurnableERC20(address(token)));

        address[] memory distributors = new address[](1);
        distributors[0] = rewards;
        escrow.initializeDistributors(distributors);

        _fund(alice, USER_BALANCE);
        _fund(bob, USER_BALANCE);
        _fund(rewards, 10_000_000e18);
    }

    function _fund(address account, uint256 amount) internal {
        vm.prank(treasury);
        token.transfer(account, amount);
        vm.prank(account);
        token.approve(address(escrow), type(uint256).max);
    }

    function _lock(address user, uint256 amount, uint256 duration) internal returns (uint256 end) {
        end = EscrowMath.roundDownToWeek(vm.getBlockTimestamp() + duration);
        vm.prank(user);
        escrow.createLock(amount, vm.getBlockTimestamp() + duration);
    }

    function _lockFor(address user, uint256 amount, uint256 duration) internal {
        vm.prank(rewards);
        escrow.createLockFor(user, amount, duration);
    }

    /// @dev Reference formula for a single lock: slope(amount) * time left.
    function _expectedBalance(uint256 amount, uint256 end, uint256 timestamp) internal pure returns (uint256) {
        if (timestamp >= end) return 0;
        return (amount / MAX_LOCK) * (end - timestamp);
    }

    function _lockOf(address user) internal view returns (uint256 amount, uint256 granted, uint256 end) {
        return escrow.locked(user);
    }
}
