// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {SeasonRewards} from "../../src/distribution/SeasonRewards.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {FeeDistributor} from "../../src/revenue/FeeDistributor.sol";
import {IEthDepositor, RevenueRouter} from "../../src/revenue/RevenueRouter.sol";
import {Treasury} from "../../src/revenue/Treasury.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockGasPriceOracle} from "../mocks/MockGasPriceOracle.sol";
import {MockL1Block} from "../mocks/MockL1Block.sol";
import {MockSeasonRegistry} from "../mocks/MockSeasonRegistry.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Revenue from end to end, deployed in the launch order: WETH reaches the router, a keeper distributes it
/// through the treasury, holders claim their weekly share, and the season closes with a treasury top-up that
/// forecasters claim locked.
contract RevenueFlowTest is Test {
    uint256 internal constant GENESIS = 1_799_971_200;
    uint256 internal constant L1_START = 21_000_000;

    uint256 internal constant DISTRIBUTE = 0;
    uint256 internal constant REGISTER = 1;
    uint256 internal constant CLOSE = 2;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    MockWETH internal weth;
    MockSeasonRegistry internal registry;
    Treasury internal treasury;
    SeasonRewards internal rewards;
    FeeDistributor internal feeDistributor;
    RevenueRouter internal router;

    address internal keeper = makeAddr("keeper");
    address internal holder = makeAddr("holder");
    address internal forecaster = makeAddr("forecaster");

    function setUp() public {
        vm.warp(GENESIS);
        new MockL1Block().install(vm, uint64(L1_START));
        new MockGasPriceOracle().install(vm, 1e12);
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        weth = new MockWETH();
        registry = new MockSeasonRegistry(GENESIS);
        registry.setNextRoundToResolve(type(uint256).max);

        address governance = makeAddr("governance");
        treasury = new Treasury(IBurnableERC20(address(tenax)), IWETH(address(weth)), escrow, governance);
        rewards = new SeasonRewards(
            tenax,
            IWETH(address(weth)),
            escrow,
            ForecastRegistry(address(registry)),
            new EmissionSchedule(L1_START),
            treasury
        );
        feeDistributor = new FeeDistributor(IWETH(address(weth)), escrow);
        router = new RevenueRouter(
            IWETH(address(weth)),
            IEthDepositor(address(rewards)),
            IEthDepositor(address(feeDistributor)),
            address(treasury),
            governance
        );

        Treasury.Task[] memory tasks = new Treasury.Task[](3);
        tasks[DISTRIBUTE] = Treasury.Task(address(router), RevenueRouter.distribute.selector, 1 days, 4);
        tasks[REGISTER] = Treasury.Task(address(rewards), SeasonRewards.register.selector, 0, 68);
        tasks[CLOSE] = Treasury.Task(address(rewards), SeasonRewards.closeSeason.selector, 0, 36);
        treasury.initialize(rewards, tasks);

        address[] memory distributors = new address[](2);
        distributors[0] = address(rewards);
        distributors[1] = address(treasury);
        escrow.initializeDistributors(distributors);
        tenax.transfer(address(rewards), 35_000_000e18);
        tenax.transfer(address(treasury), 20_000_000e18);

        tenax.transfer(holder, 10_000e18);
        vm.startPrank(holder);
        tenax.approve(address(escrow), 10_000e18);
        escrow.createLock(10_000e18, GENESIS + 104 weeks);
        vm.stopPrank();

        vm.fee(0.005 gwei);
        vm.txGasPrice(0.006 gwei);
    }

    /// @dev Stands in for the liquidity vault: pool fees arrive at the router as WETH.
    function _poolFees(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(router), amount);
    }

    function _keeper(uint256 taskId, bytes memory data) internal {
        vm.prank(keeper);
        treasury.execute(taskId, data);
    }

    function test_revenueFlowsToHoldersForecastersAndTheTreasury() public {
        // Week 1 of season 0: 0.1 ETH of fees, distributed by a keeper who is paid from the treasury's 20%.
        vm.warp(GENESIS + 8 days);
        _poolFees(0.1 ether);
        _keeper(DISTRIBUTE, abi.encodeCall(RevenueRouter.distribute, ()));
        uint256 keeperEth = weth.balanceOf(keeper);
        assertGt(keeperEth, 0, "keeper refunded in WETH");
        assertEq(weth.balanceOf(address(treasury)), 0.02 ether - keeperEth);
        assertEq(rewards.ethReceived(0), 0.04 ether);
        assertEq(weth.balanceOf(address(feeDistributor)), 0.04 ether);

        // A day later more fees arrive, but the distribution task has a one-day interval.
        _poolFees(0.05 ether);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TooSoon.selector, GENESIS + 9 days));
        treasury.execute(DISTRIBUTE, abi.encodeCall(RevenueRouter.distribute, ()));
        router.distribute(); // anyone can still distribute, unpaid

        // Holders claim the weeks that ended.
        vm.warp(GENESIS + 22 days);
        uint256 holderEth = feeDistributor.claim(holder);
        assertApproxEqAbs(holderEth, 0.06 ether, 1, "the only holder takes the whole 40%");

        // The forecaster is eligible for season 0 and registered by a keeper.
        registry.setContribution(forecaster, 0, 5e8);
        vm.warp(rewards.registrationStart(0));
        _keeper(REGISTER, abi.encodeCall(SeasonRewards.register, (forecaster, 0)));
        vm.warp(rewards.registrationStart(0) + rewards.REGISTRATION_PERIOD());
        _keeper(CLOSE, abi.encodeCall(SeasonRewards.closeSeason, (0)));

        // Season 0 received 0.06 ETH, below the 0.07 ETH target: the top-up is 1/7 of the allowance.
        uint256 allowance = treasury.allowanceOf(0);
        uint256 topUp = allowance * (0.07 ether - 0.06 ether) / 0.07 ether;
        SeasonRewards.Season memory season = rewards.seasonInfo(0);
        assertEq(season.ethBudget, 0.06 ether);
        assertEq(season.tenaxBudget, topUp, "no L1 blocks passed, so the budget is the top-up");
        assertEq(treasury.totalBurned(), allowance - topUp);

        vm.prank(forecaster);
        rewards.claimAsEth(0);
        assertEq(forecaster.balance, 0.06 ether);
        (uint256 locked, uint256 granted,) = escrow.locked(forecaster);
        assertEq(locked, topUp);
        assertEq(granted, topUp);

        // Every wei of revenue is accounted for.
        uint256 treasuryEth = weth.balanceOf(address(treasury));
        uint256 dust = weth.balanceOf(address(feeDistributor)) + weth.balanceOf(address(rewards));
        assertLe(dust, 2);
        assertEq(forecaster.balance + holderEth + treasuryEth + weth.balanceOf(keeper) + dust, 0.15 ether);
        assertEq(treasury.totalKeeperEth(), weth.balanceOf(keeper));
    }
}
