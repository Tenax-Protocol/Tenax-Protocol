// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {SeasonRewards} from "../../src/distribution/SeasonRewards.sol";
import {IBurnableERC20} from "../../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {IPriceObserver} from "../../src/interfaces/IPriceObserver.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {LiquidityVault} from "../../src/liquidity/LiquidityVault.sol";
import {RevenueRouter} from "../../src/revenue/RevenueRouter.sol";
import {Treasury} from "../../src/revenue/Treasury.sol";
import {MockSeasonRegistry} from "../mocks/MockSeasonRegistry.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {LiquidityScenarios} from "../utils/LiquidityScenarios.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev Liquidity vault and treasury buyback against Uniswap v4 compiled from source.
contract LiquidityVaultTest is LiquidityScenarios {
    function _uniswap() internal override returns (IPoolManager manager, IPositionManager posm, IWETH w) {
        manager = new PoolManager(address(this));
        w = IWETH(address(new MockWETH()));
        // Permit2 and the token descriptor are never used here; the position manager pays from its own balance.
        bytes memory args = abi.encode(address(manager), address(0xdead), 100_000, address(0), address(w));
        posm = IPositionManager(deployCode("PositionManager.sol:PositionManager", args));
    }

    // --- vault -------------------------------------------------------------------

    function test_collectFees_atMostOnceADay() public {
        _buy(1 ether);
        vault.collectFees();
        uint256 next = vm.getBlockTimestamp() + 24 hours;
        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(LiquidityVault.TooSoon.selector, next));
        vault.collectFees();
        vm.warp(next);
        vault.collectFees(); // nothing new: still succeeds, collecting zero
        assertApproxEqAbs(vault.totalEthCollected(), 0.003 ether, 1e3);
    }

    function test_collectFees_withoutFeesSendsNothing() public {
        vault.collectFees();
        assertEq(vault.totalEthCollected(), 0);
        assertEq(vault.totalTenaxBurned(), 0);
        assertEq(seasonRewards.received(), 0);
    }

    function test_RevertWhen_collectingWithoutAPosition() public {
        LiquidityVault empty = new LiquidityVault(positionManager, IBurnableERC20(address(tenax)), weth, router);
        vm.expectRevert(LiquidityVault.NoPosition.selector);
        empty.collectFees();
        assertEq(empty.positionLiquidity(), 0);
    }

    function test_RevertWhen_initializedTwiceOrWrongly() public {
        vm.expectRevert(LiquidityVault.AlreadyInitialized.selector);
        vault.initialize(tokenId);

        LiquidityVault fresh = new LiquidityVault(positionManager, IBurnableERC20(address(tenax)), weth, router);
        vm.prank(trader);
        vm.expectRevert(LiquidityVault.NotInitializer.selector);
        fresh.initialize(tokenId);
        vm.expectRevert(LiquidityVault.NotOwnedByVault.selector);
        fresh.initialize(tokenId); // owned by the other vault

        // A position in a pool that is not native ETH / TENAX.
        MockWETH other = new MockWETH();
        (address low, address high) =
            address(other) < address(tenax) ? (address(other), address(tenax)) : (address(tenax), address(other));
        key = PoolKey(Currency.wrap(low), Currency.wrap(high), 3000, TICK_SPACING, IHooks(address(0)));
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(0));
        uint256 id = positionManager.nextTokenId();
        _mintOtherPosition(address(fresh), address(other));
        vm.expectRevert(LiquidityVault.WrongPool.selector);
        fresh.initialize(id);
    }

    function test_RevertWhen_ethComesFromAnywhereButThePoolManager() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory reason) = address(vault).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(reason), LiquidityVault.UnexpectedEth.selector);
    }

    function test_RevertWhen_vaultConstructorArgumentsAreInvalid() public {
        IBurnableERC20 t = IBurnableERC20(address(tenax));
        vm.expectRevert(LiquidityVault.ZeroAddress.selector);
        new LiquidityVault(IPositionManager(address(0)), t, weth, router);
        vm.expectRevert(LiquidityVault.ZeroAddress.selector);
        new LiquidityVault(positionManager, IBurnableERC20(address(0)), weth, router);
        vm.expectRevert(LiquidityVault.ZeroAddress.selector);
        new LiquidityVault(positionManager, t, IWETH(address(0)), router);
        vm.expectRevert(LiquidityVault.ZeroAddress.selector);
        new LiquidityVault(positionManager, t, weth, RevenueRouter(address(0)));
        vm.expectRevert(LiquidityVault.TokenMismatch.selector);
        new LiquidityVault(positionManager, t, IWETH(address(new MockWETH())), router);
    }

    // --- treasury buyback --------------------------------------------------------

    function test_buyback_atMostOnceADay() public {
        _fundTreasury(1 ether);
        observer.setMeanTick(_tick());
        treasury.buyback();
        uint256 next = vm.getBlockTimestamp() + 24 hours;
        vm.warp(next - 1);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TooSoon.selector, next));
        treasury.buyback();
        vm.warp(next);
        observer.setMeanTick(_tick());
        treasury.buyback();
        assertEq(treasury.totalBuybackEth(), 0.1 ether);
    }

    function test_RevertWhen_thereIsNoSurplusAboveTheKeeperReserve() public {
        _fundTreasury(treasury.ethReserveTarget());
        vm.expectRevert(Treasury.NoSurplus.selector);
        treasury.buyback();
    }

    function test_buyback_spendsOnlyWhatIsAboveTheReserve() public {
        _fundTreasury(treasury.ethReserveTarget() + 0.01 ether);
        observer.setMeanTick(_tick());
        treasury.buyback();
        assertEq(treasury.totalBuybackEth(), 0.01 ether);
        assertEq(weth.balanceOf(address(treasury)), treasury.ethReserveTarget());
    }

    function test_RevertWhen_unlockCallbackIsNotFromThePoolManager() public {
        vm.expectRevert(Treasury.NotPoolManager.selector);
        treasury.unlockCallback(abi.encode(uint256(1)));
    }

    function test_RevertWhen_ethIsSentToTheTreasury() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory reason) = address(treasury).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(reason), Treasury.UnexpectedEth.selector);
    }

    function test_marketSetup() public {
        assertEq(address(treasury.poolManager()), address(poolManager));
        assertEq(address(treasury.priceObserver()), address(observer));
        assertEq(Currency.unwrap(treasury.poolKey().currency1), address(tenax));
        assertEq(treasury.buybackCap(), 0.05 ether);

        vm.expectRevert(Treasury.AlreadyInitialized.selector);
        treasury.initializeMarket(poolManager, key, observer);

        Treasury fresh = new Treasury(IBurnableERC20(address(tenax)), weth, treasury.escrow(), governance);
        vm.expectRevert(Treasury.MarketNotInitialized.selector);
        fresh.buyback();
        vm.prank(trader);
        vm.expectRevert(Treasury.NotInitializer.selector);
        fresh.initializeMarket(poolManager, key, observer);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        fresh.initializeMarket(IPoolManager(address(0)), key, observer);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        fresh.initializeMarket(poolManager, key, IPriceObserver(address(0)));
        PoolKey memory wrong = key;
        wrong.currency1 = Currency.wrap(address(weth));
        vm.expectRevert(Treasury.WrongPool.selector);
        fresh.initializeMarket(poolManager, wrong, observer);
    }

    function test_setBuybackCap_withinBoundsByGovernance() public {
        vm.expectRevert(Treasury.NotGovernance.selector);
        treasury.setBuybackCap(1 ether);
        vm.startPrank(governance);
        vm.expectRevert(Treasury.OutOfBounds.selector);
        treasury.setBuybackCap(0.0009 ether);
        vm.expectRevert(Treasury.OutOfBounds.selector);
        treasury.setBuybackCap(10.1 ether);
        treasury.setBuybackCap(1 ether);
        vm.stopPrank();
        assertEq(treasury.buybackCap(), 1 ether);
    }

    // --- keeper tasks ------------------------------------------------------------

    function test_keeperTasks_collectFeesAndBuybackArePaid() public {
        SeasonRewards rewards = new SeasonRewards(
            tenax,
            weth,
            treasury.escrow(),
            ForecastRegistry(address(new MockSeasonRegistry(vm.getBlockTimestamp()))),
            new EmissionSchedule(0),
            treasury
        );
        Treasury.Task[] memory tasks = new Treasury.Task[](2);
        tasks[0] = Treasury.Task(address(vault), LiquidityVault.collectFees.selector, 1 days, 4);
        tasks[1] = Treasury.Task(address(treasury), Treasury.buyback.selector, 1 days, 4);
        treasury.initialize(rewards, tasks);
        address keeper = makeAddr("keeper");
        vm.fee(0.005 gwei);
        vm.txGasPrice(0.006 gwei);

        // A day of trading, then the keeper collects: 20% of the ETH fees reach the treasury and pay the keeper.
        _buy(20 ether);
        vm.prank(keeper);
        treasury.execute(0, abi.encodeCall(LiquidityVault.collectFees, ()));
        uint256 keeperPaid = weth.balanceOf(keeper);
        assertGt(keeperPaid, 0);
        uint256 toTreasury = vault.totalEthCollected() - 2 * (vault.totalEthCollected() * 4000 / 10_000);
        assertEq(weth.balanceOf(address(treasury)), toTreasury - keeperPaid);

        // With a surplus above the keeper reserve, the keeper runs the buyback through the treasury itself.
        _fundTreasury(1 ether);
        observer.setMeanTick(_tick());
        uint256 supply = tenax.totalSupply();
        vm.prank(keeper);
        treasury.execute(1, abi.encodeCall(Treasury.buyback, ()));
        assertEq(treasury.totalBuybackEth(), 0.05 ether);
        assertEq(supply - tenax.totalSupply(), treasury.totalBuybackBurned());
        assertGt(weth.balanceOf(keeper), keeperPaid, "paid again");
    }

    // --- helpers -----------------------------------------------------------------

    /// @dev Full-range position in `key` (an ERC-20 pair), funded from the position manager's own balance.
    function _mintOtherPosition(address owner, address other) internal {
        MockWETH(payable(other)).deposit{value: 0}();
        vm.deal(address(this), 10 ether);
        MockWETH(payable(other)).deposit{value: 10 ether}();
        MockWETH(payable(other)).transfer(address(positionManager), 10 ether);
        tenax.transfer(address(positionManager), 10 ether);
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        bytes memory actions = abi.encodePacked(uint8(0x02), uint8(0x0b), uint8(0x0b));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lower, upper, uint256(1e18), uint128(10 ether), uint128(10 ether), owner, "");
        params[1] = abi.encode(key.currency0, uint256(0), false);
        params[2] = abi.encode(key.currency1, uint256(0), false);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }
}
