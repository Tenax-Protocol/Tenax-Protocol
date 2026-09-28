// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Treasury} from "../../src/revenue/Treasury.sol";
import {LiquidityTestBase} from "./LiquidityTestBase.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";

/// @dev Fee collection and buyback scenarios, run against local Uniswap and against the live Base deployment.
abstract contract LiquidityScenarios is LiquidityTestBase {
    function test_launch_positionHoldsOnlyTenaxAndBelongsToTheVault() public view {
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), address(vault));
        assertEq(vault.tokenId(), tokenId);
        assertGt(vault.positionLiquidity(), 0);
        assertEq(_tick(), LAUNCH_TICK);
        assertLe(tenax.balanceOf(address(positionManager)), 0, "the position manager kept nothing");
    }

    function test_collectFees_sendsEthToRevenueAndBurnsTenax() public {
        _buy(1 ether);
        assertLt(_tick(), LAUNCH_TICK, "buying TENAX lowers the tick");
        _sell(100_000e18);

        uint128 liquidity = vault.positionLiquidity();
        uint256 supply = tenax.totalSupply();
        uint256 treasuryBefore = weth.balanceOf(address(treasury));
        vault.collectFees();

        // The vault is the only liquidity provider, so it earns the whole 0.3% fee on both swaps.
        uint256 eth = vault.totalEthCollected();
        assertApproxEqAbs(eth, 0.003 ether, 1e3);
        assertApproxEqAbs(supply - tenax.totalSupply(), 300e18, 1e3, "TENAX fees burned");
        assertEq(vault.totalTenaxBurned(), supply - tenax.totalSupply());

        assertEq(seasonRewards.received(), eth * 4000 / 10_000);
        assertEq(feeDistributor.received(), eth * 4000 / 10_000);
        assertEq(weth.balanceOf(address(treasury)) - treasuryBefore, eth - 2 * (eth * 4000 / 10_000));
        assertEq(address(vault).balance + weth.balanceOf(address(vault)) + tenax.balanceOf(address(vault)), 0);
        assertEq(vault.positionLiquidity(), liquidity, "liquidity never decreases");
    }

    function test_buyback_spendsTheSurplusUpToTheCapAndBurnsWhatItBuys() public {
        _fundTreasury(1 ether);
        observer.setMeanTick(_tick());
        uint256 supply = tenax.totalSupply();

        treasury.buyback();

        uint256 burned = supply - tenax.totalSupply();
        assertEq(treasury.totalBuybackEth(), 0.05 ether, "capped at 0.05 ETH");
        assertEq(weth.balanceOf(address(treasury)), 0.95 ether);
        assertEq(treasury.totalBuybackBurned(), burned);
        assertGt(burned, 40_000e18, "about 1e6 TENAX per ETH, minus fee and price impact");
        assertEq(tenax.balanceOf(address(treasury)), 0);
        assertEq(address(treasury).balance, 0);
    }

    function test_buyback_stopsTwoPercentBelowTheAverage() public {
        vm.prank(governance);
        treasury.setBuybackCap(10 ether);
        _fundTreasury(10 ether + treasury.ethReserveTarget());
        int24 mean = _tick();
        observer.setMeanTick(mean);

        treasury.buyback();

        uint256 spent = treasury.totalBuybackEth();
        assertLt(spent, 1 ether, "the 2% band holds far less than the cap");
        assertGe(_tick(), mean - treasury.MAX_TICK_DEVIATION() - 1);
        assertEq(weth.balanceOf(address(treasury)), 10 ether + treasury.ethReserveTarget() - spent, "rest rewrapped");
        assertEq(address(treasury).balance, 0);
    }

    function test_RevertWhen_priceDeviatesFromTheAverage() public {
        _fundTreasury(1 ether);
        int24 tick = _tick();
        int24 deviation = treasury.MAX_TICK_DEVIATION();

        observer.setMeanTick(tick + deviation + 1);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PriceDeviation.selector, tick, tick + deviation + 1));
        treasury.buyback();

        observer.setMeanTick(tick - deviation - 1);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PriceDeviation.selector, tick, tick - deviation - 1));
        treasury.buyback();

        // At the lower edge the swap would have no room to buy anything.
        observer.setMeanTick(tick + deviation);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PriceDeviation.selector, tick, tick + deviation));
        treasury.buyback();

        observer.setMeanTick(tick + deviation - 1);
        treasury.buyback();
        assertGt(treasury.totalBuybackBurned(), 0);
    }

    function test_buyback_runsAtTheUpperEdgeOfTheBand() public {
        _fundTreasury(1 ether);
        observer.setMeanTick(_tick() - treasury.MAX_TICK_DEVIATION());
        treasury.buyback();
        assertEq(treasury.totalBuybackEth(), 0.05 ether);
    }
}
