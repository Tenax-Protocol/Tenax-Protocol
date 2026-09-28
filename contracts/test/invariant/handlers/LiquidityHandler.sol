// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWETH} from "../../../src/interfaces/IWETH.sol";
import {LiquidityVault} from "../../../src/liquidity/LiquidityVault.sol";
import {Treasury} from "../../../src/revenue/Treasury.sol";
import {TenaxToken} from "../../../src/token/TenaxToken.sol";
import {MockPriceObserver} from "../../mocks/MockPriceObserver.sol";
import {V4Swapper} from "../../utils/V4Swapper.sol";
import {Test} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Trades in the protocol's pool, collects fees and runs buybacks in random valid sequences, with the average
/// price anywhere inside the band that lets a buyback run. Tracks the WETH the treasury should hold.
contract LiquidityHandler is Test {
    using StateLibrary for IPoolManager;

    LiquidityVault public immutable vault;
    Treasury public immutable treasury;
    TenaxToken public immutable tenax;
    IWETH public immutable weth;
    IPoolManager public immutable poolManager;
    V4Swapper public immutable swapper;
    MockPriceObserver public immutable observer;
    address public immutable trader;

    PoolKey internal _key;

    uint256 public ghostTreasuryWeth;

    /// @dev TENAX the pool sold to the trader and not yet bought back. The protocol position has no liquidity
    /// above the launch price, so selling more than this would find no buyer.
    uint256 public ghostNetBought;
    mapping(string operation => uint256 count) public executed;

    constructor(
        LiquidityVault vault_,
        Treasury treasury_,
        V4Swapper swapper_,
        MockPriceObserver observer_,
        PoolKey memory key_,
        address trader_
    ) {
        vault = vault_;
        treasury = treasury_;
        tenax = TenaxToken(address(vault_.token()));
        weth = vault_.weth();
        poolManager = treasury_.poolManager();
        swapper = swapper_;
        observer = observer_;
        _key = key_;
        trader = trader_;
    }

    function buy(uint256 amount) external {
        amount = bound(amount, 0.001 ether, 5 ether);
        vm.deal(trader, trader.balance + amount);
        vm.prank(trader);
        ghostNetBought += swapper.buy{value: amount}(_key);
        _record("buy");
    }

    function sell(uint256 amount) external {
        if (ghostNetBought < 1e18) return;
        amount = bound(amount, 1e18, ghostNetBought);
        ghostNetBought -= amount;
        vm.prank(trader);
        swapper.sell(_key, amount);
        _record("sell");
    }

    function collectFees() external {
        uint256 next = vault.lastCollect() + vault.COLLECT_INTERVAL();
        if (vault.lastCollect() != 0 && vm.getBlockTimestamp() < next) vm.warp(next);
        uint256 before = vault.totalEthCollected();
        vault.collectFees();
        uint256 eth = vault.totalEthCollected() - before;
        ghostTreasuryWeth += eth - 2 * (eth * 4000 / 10_000);
        _record("collectFees");
    }

    function fundTreasury(uint256 amount) external {
        amount = bound(amount, 0.001 ether, 1 ether);
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(treasury), amount);
        ghostTreasuryWeth += amount;
        _record("fundTreasury");
    }

    function buyback(int256 offset) external {
        if (weth.balanceOf(address(treasury)) <= treasury.ethReserveTarget()) return;
        uint256 next = treasury.lastBuyback() + treasury.BUYBACK_INTERVAL();
        if (treasury.lastBuyback() != 0 && vm.getBlockTimestamp() < next) vm.warp(next);
        (, int24 tick,,) = poolManager.getSlot0(_key.toId());
        int24 deviation = treasury.MAX_TICK_DEVIATION();
        observer.setMeanTick(tick + int24(bound(offset, -deviation, deviation - 1)));

        uint256 before = treasury.totalBuybackEth();
        treasury.buyback();
        ghostTreasuryWeth -= treasury.totalBuybackEth() - before;
        _record("buyback");
    }

    function warp(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1 minutes, 3 days));
        _record("warp");
    }

    function _record(string memory operation) internal {
        ++executed[operation];
    }

    receive() external payable {}
}
