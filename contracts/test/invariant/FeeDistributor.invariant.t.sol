// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {FeeDistributor} from "../../src/revenue/FeeDistributor.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {FeeHandler} from "./handlers/FeeHandler.sol";
import {Test, console} from "forge-std/Test.sol";

/// forge-config: default.invariant.depth = 150
/// forge-config: default.invariant.runs = 64
/// forge-config: ci.invariant.depth = 250
/// forge-config: ci.invariant.runs = 128
contract FeeDistributorInvariantTest is Test {
    uint256 internal constant WEEK = 1 weeks;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    MockWETH internal weth;
    FeeDistributor internal distributor;
    FeeHandler internal handler;

    function setUp() public {
        vm.warp(1_800_000_000);
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        weth = new MockWETH();
        distributor = new FeeDistributor(IWETH(address(weth)), escrow);

        address[] memory actors = new address[](6);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("holder-", vm.toString(i)));
            tenax.transfer(actors[i], 1_000_000e18);
            vm.prank(actors[i]);
            tenax.approve(address(escrow), type(uint256).max);
        }
        address router = makeAddr("router");
        vm.deal(router, 1_000_000 ether);
        vm.startPrank(router);
        weth.deposit{value: 1_000_000 ether}();
        weth.approve(address(distributor), type(uint256).max);
        vm.stopPrank();

        handler = new FeeHandler(distributor, weth, router, actors);
        targetContract(address(handler));
    }

    /// @dev Whitepaper invariant: fee distributions never pay more than they received.
    function invariant_paysNoMoreThanReceived() public view {
        assertLe(handler.ghostClaimed(), handler.ghostDeposited());
        assertEq(weth.balanceOf(address(distributor)), handler.ghostDeposited() - handler.ghostClaimed());
    }

    /// @dev Rollovers move revenue between weeks without creating or losing any.
    function invariant_weeklyRevenueIsConserved() public view {
        uint256 sum;
        uint256 last = vm.getBlockTimestamp() / WEEK * WEEK;
        for (uint256 week = distributor.startWeek(); week <= last; week += WEEK) {
            sum += distributor.tokensPerWeek(week);
        }
        assertEq(sum, handler.ghostDeposited());
    }

    /// @dev In every final week, the holders' shares add up to at most the week's revenue, and a week that
    /// started without veTENAX keeps nothing.
    function invariant_finalWeeksNeverOverpay() public view {
        for (uint256 week = distributor.startWeek(); week < distributor.weekCursor(); week += WEEK) {
            uint256 supply = distributor.veSupply(week);
            uint256 amount = distributor.tokensPerWeek(week);
            if (supply == 0) {
                assertEq(amount, 0, "rolled over");
                continue;
            }
            uint256 shares;
            uint256 balances;
            for (uint256 i; i < handler.actorCount(); ++i) {
                uint256 balance = escrow.balanceOfAt(handler.actors(i), week);
                balances += balance;
                shares += amount * balance / supply;
            }
            assertEq(balances, supply, "holders' balances make up the supply");
            assertLe(shares, amount);
        }
    }

    function afterInvariant() external view {
        string[8] memory operations =
            ["createLock", "increaseAmount", "extend", "withdraw", "deposit", "claim", "checkpoint", "warp"];
        for (uint256 i; i < operations.length; ++i) {
            console.log(operations[i], handler.executed(operations[i]));
        }
        console.log("claimed / deposited (milli-ETH)", handler.ghostClaimed() / 1e15, handler.ghostDeposited() / 1e15);
    }
}
