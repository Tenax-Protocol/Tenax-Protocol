// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {EscrowHandler} from "./handlers/EscrowHandler.sol";
import {Test, console} from "forge-std/Test.sol";

contract VotingEscrowInvariantTest is Test {
    TenaxToken internal token;
    VotingEscrow internal escrow;
    EscrowHandler internal handler;
    address internal treasury = makeAddr("treasury");
    address internal rewards = makeAddr("rewards");

    function setUp() public {
        vm.warp(1_800_100_800);
        token = new TenaxToken(treasury);
        escrow = new VotingEscrow(IBurnableERC20(address(token)));

        address[] memory actors = new address[](8);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("actor-", vm.toString(i)));
            _fund(actors[i], 1_000_000e18);
        }
        _fund(rewards, 50_000_000e18);

        handler = new EscrowHandler(escrow, token, rewards, actors);
        address[] memory distributors = new address[](1);
        distributors[0] = rewards;
        escrow.initializeDistributors(distributors);
        targetContract(address(handler));
    }

    function _fund(address account, uint256 amount) internal {
        vm.prank(treasury);
        token.transfer(account, amount);
        vm.prank(account);
        token.approve(address(escrow), type(uint256).max);
    }

    /// @dev Whitepaper invariant: the escrow's TENAX balance covers all locks, exactly.
    function invariant_tokenBalanceEqualsLockedSupply() public view {
        assertEq(token.balanceOf(address(escrow)), escrow.supply());
    }

    function invariant_supplyEqualsSumOfLocks() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            (uint256 amount,,) = escrow.locked(handler.actors(i));
            sum += amount;
        }
        assertEq(escrow.supply(), sum);
    }

    /// @dev Whitepaper invariant: the sum of veTENAX balances equals the escrow's total supply.
    function invariant_sumOfBalancesEqualsTotalSupply() public view {
        uint256 sum;
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += escrow.balanceOf(handler.actors(i));
        }
        assertEq(escrow.totalSupply(), sum);
    }

    /// @dev The same must hold at every past timestamp recorded along the run.
    function invariant_historyIsConsistent() public view {
        uint256 count = handler.snapshotCount();
        uint256 from = count > 10 ? count - 10 : 0;
        for (uint256 s = from; s < count; ++s) {
            uint256 timestamp = handler.snapshots(s);
            uint256 sum;
            for (uint256 i; i < handler.actorCount(); ++i) {
                sum += escrow.balanceOfAt(handler.actors(i), timestamp);
            }
            assertEq(escrow.totalSupplyAt(timestamp), sum);
        }
    }

    function invariant_votingPowerNeverExceedsLockedAmount() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            (uint256 amount, uint256 granted,) = escrow.locked(actor);
            assertLe(escrow.balanceOf(actor), amount);
            assertLe(granted, amount);
        }
    }

    /// @dev Whitepaper invariant: protocol-delivered tokens never leave before unlock.
    function invariant_grantedTokensNeverLeaveEarly() public view {
        assertFalse(handler.ghostGrantedLeftEarly());
    }

    function afterInvariant() external view {
        string[6] memory operations =
            ["createLock", "increaseAmount", "increaseUnlockTime", "withdraw", "withdrawEarly", "createLockFor"];
        for (uint256 i; i < operations.length; ++i) {
            console.log(operations[i], handler.executed(operations[i]));
        }
    }

    /// @dev Early exit penalties are the only way supply changes, and they are burned.
    function invariant_tokenSupplyOnlyFallsByBurnedPenalties() public view {
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY() - handler.ghostBurned());
    }
}
