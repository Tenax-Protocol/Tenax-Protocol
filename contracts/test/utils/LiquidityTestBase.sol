// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {LiquidityVault} from "../../src/liquidity/LiquidityVault.sol";
import {IEthDepositor, RevenueRouter} from "../../src/revenue/RevenueRouter.sol";
import {Treasury} from "../../src/revenue/Treasury.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockEthDepositor} from "../mocks/MockEthDepositor.sol";
import {MockPriceObserver} from "../mocks/MockPriceObserver.sol";
import {V4Swapper} from "./V4Swapper.sol";
import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @dev Protocol liquidity on Uniswap v4: a native ETH / TENAX pool launched at 1e-6 ETH per TENAX with a
/// TENAX-only position owned by the vault, the revenue router and the treasury wired for buybacks. Concrete tests
/// choose where Uniswap comes from: compiled locally or the live deployment on a Base fork.
abstract contract LiquidityTestBase is Test {
    using StateLibrary for IPoolManager;

    uint256 internal constant POSITION_TENAX = 20_000_000e18;
    int24 internal constant TICK_SPACING = 60;

    /// @dev 1e6 TENAX per ETH (1e-6 ETH per TENAX) is tick 138,162; aligned down to the tick spacing.
    int24 internal constant LAUNCH_TICK = 138_120;

    TenaxToken internal tenax;
    IWETH internal weth;
    IPoolManager internal poolManager;
    IPositionManager internal positionManager;
    PoolKey internal key;
    uint256 internal tokenId;

    MockEthDepositor internal seasonRewards;
    MockEthDepositor internal feeDistributor;
    RevenueRouter internal router;
    Treasury internal treasury;
    LiquidityVault internal vault;
    MockPriceObserver internal observer;
    V4Swapper internal swapper;

    address internal trader = makeAddr("trader");
    address internal governance = makeAddr("governance");

    /// @dev Provides the pool manager, the position manager and WETH.
    function _uniswap() internal virtual returns (IPoolManager, IPositionManager, IWETH);

    function setUp() public virtual {
        (poolManager, positionManager, weth) = _uniswap();
        tenax = new TenaxToken(address(this));
        VotingEscrow escrow = new VotingEscrow(IBurnableERC20(address(tenax)));

        treasury = new Treasury(IBurnableERC20(address(tenax)), weth, escrow, governance);
        seasonRewards = new MockEthDepositor(weth);
        feeDistributor = new MockEthDepositor(weth);
        router = new RevenueRouter(
            weth,
            IEthDepositor(address(seasonRewards)),
            IEthDepositor(address(feeDistributor)),
            address(treasury),
            governance
        );
        vault = new LiquidityVault(positionManager, IBurnableERC20(address(tenax)), weth, router);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tenax)),
            fee: 3000,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(0))
        });
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(LAUNCH_TICK));
        tokenId = _mintLaunchPosition(address(vault), POSITION_TENAX);
        vault.initialize(tokenId);

        observer = new MockPriceObserver();
        treasury.initializeMarket(poolManager, key, observer);
        swapper = new V4Swapper(poolManager);

        vm.deal(trader, 1000 ether);
        tenax.transfer(trader, 1_000_000e18);
        vm.prank(trader);
        tenax.approve(address(swapper), type(uint256).max);
    }

    // --- helpers -----------------------------------------------------------------

    /// @dev Mints a TENAX-only position from the maximum TENAX price down to the launch price: the pool starts at
    /// the top of the range, so the position holds no ETH. The position manager pays from its own balance.
    function _mintLaunchPosition(address owner, uint256 amount) internal returns (uint256 id) {
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(LAUNCH_TICK), amount
        );
        id = positionManager.nextTokenId();
        tenax.transfer(address(positionManager), amount);

        bytes memory actions =
            abi.encodePacked(uint8(Actions.MINT_POSITION), uint8(Actions.SETTLE), uint8(Actions.SWEEP));
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lower, LAUNCH_TICK, uint256(liquidity), uint128(0), uint128(amount), owner, "");
        params[1] = abi.encode(key.currency1, uint256(0), false);
        params[2] = abi.encode(key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);
    }

    function _buy(uint256 eth) internal returns (uint256) {
        vm.prank(trader);
        return swapper.buy{value: eth}(key);
    }

    function _sell(uint256 amount) internal returns (uint256) {
        vm.prank(trader);
        return swapper.sell(key, amount);
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(key.toId());
    }

    function _fundTreasury(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(treasury), amount);
    }

    receive() external payable {}
}
