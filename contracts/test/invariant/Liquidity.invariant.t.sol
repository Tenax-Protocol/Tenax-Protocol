// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWETH} from "../../src/interfaces/IWETH.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {LiquidityTestBase} from "../utils/LiquidityTestBase.sol";
import {LiquidityHandler} from "./handlers/LiquidityHandler.sol";
import {console} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// forge-config: default.invariant.depth = 100
/// forge-config: default.invariant.runs = 64
/// forge-config: ci.invariant.depth = 200
/// forge-config: ci.invariant.runs = 128
contract LiquidityInvariantTest is LiquidityTestBase {
    LiquidityHandler internal handler;
    uint128 internal initialLiquidity;

    function _uniswap() internal override returns (IPoolManager manager, IPositionManager posm, IWETH w) {
        manager = new PoolManager(address(this));
        w = IWETH(address(new MockWETH()));
        bytes memory args = abi.encode(address(manager), address(0xdead), 100_000, address(0), address(w));
        posm = IPositionManager(deployCode("PositionManager.sol:PositionManager", args));
    }

    function setUp() public override {
        super.setUp();
        initialLiquidity = vault.positionLiquidity();
        handler = new LiquidityHandler(vault, treasury, swapper, observer, key, trader);
        targetContract(address(handler));
    }

    /// @dev Whitepaper invariant: the liquidity of the protocol position never decreases.
    function invariant_positionLiquidityNeverDecreases() public view {
        assertEq(vault.positionLiquidity(), initialLiquidity);
        assertEq(address(vault).balance + weth.balanceOf(address(vault)) + tenax.balanceOf(address(vault)), 0);
    }

    /// @dev Whitepaper invariant: all bought-back TENAX, like all TENAX fees, is burned.
    function invariant_everyTenaxBoughtOrCollectedIsBurned() public view {
        assertEq(tenax.balanceOf(address(treasury)), 0);
        assertEq(tenax.totalSupply(), tenax.INITIAL_SUPPLY() - vault.totalTenaxBurned() - treasury.totalBuybackBurned());
    }

    /// @dev Whitepaper invariant: the treasury only sends ETH to buybacks (no keepers run here), and never spends
    /// the keeper reserve on them.
    function invariant_treasuryEthIsAccountedFor() public view {
        assertEq(weth.balanceOf(address(treasury)), handler.ghostTreasuryWeth());
        assertEq(address(treasury).balance, 0);
        assertEq(weth.balanceOf(address(router)), 0);
    }

    function afterInvariant() external view {
        string[6] memory operations = ["buy", "sell", "collectFees", "fundTreasury", "buyback", "warp"];
        for (uint256 i; i < operations.length; ++i) {
            console.log(operations[i], handler.executed(operations[i]));
        }
        console.log("TENAX burned by buybacks", treasury.totalBuybackBurned() / 1e18);
    }
}
