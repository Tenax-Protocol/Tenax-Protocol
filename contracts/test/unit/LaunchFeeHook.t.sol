// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {LaunchFeeHook} from "../../src/hooks/LaunchFeeHook.sol";
import {PoolLauncher} from "../../src/launch/PoolLauncher.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {V4Swapper} from "../utils/V4Swapper.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test, Vm} from "forge-std/Test.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

contract LaunchFeeHookTest is Test {
    using StateLibrary for IPoolManager;

    int24 internal constant LAUNCH_TICK = 138_120;
    uint160 internal constant FLAGS =
        uint160(Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG);

    IPoolManager internal poolManager;
    IPositionManager internal positionManager;
    TenaxToken internal tenax;
    PoolLauncher internal launcher;
    LaunchFeeHook internal hook;
    V4Swapper internal swapper;
    PoolKey internal key;

    address internal vault = makeAddr("vault");
    address internal trader = makeAddr("trader");

    /// @dev Tick history for the reference average: the tick in force from each timestamp on.
    uint256[] internal changeTimes;
    int24[] internal changeTicks;

    function setUp() public {
        vm.warp(1_800_000_000);
        vm.roll(1000);
        poolManager = new PoolManager(address(this));
        bytes memory args = abi.encode(address(poolManager), address(0xdead), 100_000, address(0), address(0xbeef));
        positionManager = IPositionManager(deployCode("PositionManager.sol:PositionManager", args));
        tenax = new TenaxToken(address(this));
        launcher = new PoolLauncher(poolManager, positionManager, tenax);

        address hookAddress = address(uint160(uint256(keccak256("tenax hook")) & ~uint256(Hooks.ALL_HOOK_MASK)) | FLAGS);
        deployCodeTo(
            "LaunchFeeHook.sol:LaunchFeeHook", abi.encode(poolManager, address(launcher), address(tenax)), hookAddress
        );
        hook = LaunchFeeHook(hookAddress);

        key = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(tenax)),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddress)
        });
        swapper = new V4Swapper(poolManager);
        vm.deal(trader, 10_000 ether);
        vm.prank(trader);
        tenax.approve(address(swapper), type(uint256).max);
    }

    function _launch() internal returns (uint256 tokenId) {
        tenax.transfer(address(launcher), 20_000_000e18);
        tokenId = launcher.launch(key, LAUNCH_TICK, vault);
        _recordTick();
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(key.toId());
    }

    function _recordTick() internal {
        changeTimes.push(vm.getBlockTimestamp());
        changeTicks.push(_tick());
    }

    /// @dev Swaps in a new block `gap` seconds later and records the tick it leaves.
    function _buyAfter(uint256 gap, uint256 eth) internal returns (uint24 fee) {
        vm.warp(vm.getBlockTimestamp() + gap);
        vm.roll(vm.getBlockNumber() + 1);
        vm.recordLogs();
        vm.prank(trader);
        swapper.buy{value: eth}(key);
        fee = _swapFee();
        _recordTick();
    }

    function _sellAfter(uint256 gap, uint256 amount) internal {
        vm.warp(vm.getBlockTimestamp() + gap);
        vm.roll(vm.getBlockNumber() + 1);
        vm.prank(trader);
        swapper.sell(key, amount);
        _recordTick();
    }

    function _swapFee() internal returns (uint24 fee) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    /// @dev Time-weighted average of the recorded ticks over the last `window` seconds, rounded down.
    function _referenceMean(uint32 window) internal view returns (int24) {
        uint256 end = vm.getBlockTimestamp();
        uint256 start = end - window;
        int256 sum;
        for (uint256 i; i < changeTimes.length; ++i) {
            uint256 from = changeTimes[i] > start ? changeTimes[i] : start;
            uint256 to = i + 1 < changeTimes.length ? changeTimes[i + 1] : end;
            if (to > end) to = end;
            if (to > from) sum += int256(changeTicks[i]) * int256(to - from);
        }
        int256 mean = sum / int256(uint256(window));
        if (sum < 0 && sum % int256(uint256(window)) != 0) --mean;
        return int24(mean);
    }

    // --- launch ------------------------------------------------------------------

    function test_launch_createsThePoolWithTheVaultPosition() public {
        uint256 tokenId = _launch();
        assertEq(_tick(), LAUNCH_TICK);
        assertEq(IERC721(address(positionManager)).ownerOf(tokenId), vault);
        assertGt(positionManager.getPositionLiquidity(tokenId), 0);
        assertTrue(hook.launched());
        assertEq(hook.launchBlock(), vm.getBlockNumber());
        assertEq(hook.observationCount(), 1);
        assertTrue(launcher.launched());
        assertEq(tenax.balanceOf(address(launcher)), 0);
        assertLe(tenax.balanceOf(vault), 1e6, "only rounding dust swept to the vault");
    }

    function test_RevertWhen_anyoneButTheLauncherInitializes() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(LaunchFeeHook.NotLauncher.selector, address(this)),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(LAUNCH_TICK));
    }

    function test_RevertWhen_theHookIsUsedForASecondPool() public {
        _launch();
        PoolLauncher other = new PoolLauncher(poolManager, positionManager, tenax);
        vm.expectRevert(abi.encodeWithSelector(PoolLauncher.AlreadyLaunched.selector));
        launcher.launch(key, LAUNCH_TICK, vault);

        PoolKey memory second = key;
        second.tickSpacing = 120;
        vm.prank(address(launcher));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(LaunchFeeHook.AlreadyLaunched.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        poolManager.initialize(second, TickMath.getSqrtPriceAtTick(0));
        assertFalse(other.launched());
    }

    function test_RevertWhen_thePoolIsNotDynamicEthTenax() public {
        tenax.transfer(address(launcher), 20_000_000e18);
        PoolKey memory wrong = key;
        wrong.fee = 3000;
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(LaunchFeeHook.WrongPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        launcher.launch(wrong, LAUNCH_TICK, vault);

        TenaxToken other = new TenaxToken(address(this));
        wrong = key;
        wrong.currency1 = Currency.wrap(address(other));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(LaunchFeeHook.WrongPool.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        launcher.launch(wrong, LAUNCH_TICK, vault);

        launcher.launch(key, LAUNCH_TICK, vault); // the failed attempts left no trace
        assertTrue(hook.launched());
    }

    function test_RevertWhen_launchIsMisusedOrMisconfigured() public {
        vm.prank(trader);
        vm.expectRevert(PoolLauncher.NotOwner.selector);
        launcher.launch(key, LAUNCH_TICK, vault);
        vm.expectRevert(abi.encodeWithSelector(PoolLauncher.TickNotAligned.selector, int24(138_162)));
        launcher.launch(key, 138_162, vault);
        vm.expectRevert(PoolLauncher.ZeroAddress.selector);
        launcher.launch(key, LAUNCH_TICK, address(0));

        vm.expectRevert(PoolLauncher.ZeroAddress.selector);
        new PoolLauncher(IPoolManager(address(0)), positionManager, tenax);
        vm.expectRevert(PoolLauncher.ZeroAddress.selector);
        new PoolLauncher(poolManager, IPositionManager(address(0)), tenax);
        vm.expectRevert(PoolLauncher.ZeroAddress.selector);
        new PoolLauncher(poolManager, positionManager, IERC20(address(0)));
    }

    function test_RevertWhen_hookConstructorArgumentsAreZero() public {
        address at = address(uint160(uint256(keccak256("other hook")) & ~uint256(Hooks.ALL_HOOK_MASK)) | FLAGS);
        vm.expectRevert(LaunchFeeHook.ZeroAddress.selector);
        deployCodeTo("LaunchFeeHook.sol:LaunchFeeHook", abi.encode(poolManager, address(0), address(tenax)), at);
        vm.expectRevert(LaunchFeeHook.ZeroAddress.selector);
        deployCodeTo("LaunchFeeHook.sol:LaunchFeeHook", abi.encode(poolManager, address(launcher), address(0)), at);
    }

    // --- launch fee --------------------------------------------------------------

    function test_fee_decaysFrom20PercentTo0point3PercentOver300Blocks() public {
        _launch();
        assertEq(hook.currentFee(), uint24(200_000));
        vm.roll(vm.getBlockNumber() + 150);
        assertEq(hook.currentFee(), uint24(101_500));
        vm.roll(vm.getBlockNumber() + 149);
        assertEq(hook.currentFee(), uint24(3657)); // one block before the end: 200,000 - 197,000 * 299 / 300, rounded down
        vm.roll(vm.getBlockNumber() + 1);
        assertEq(hook.currentFee(), uint24(3000));
        vm.roll(vm.getBlockNumber() + 100_000);
        assertEq(hook.currentFee(), uint24(3000));
    }

    function test_fee_isChargedOnSwaps() public {
        _launch();
        vm.roll(vm.getBlockNumber() - 1); // the first swap lands in the launch block
        assertEq(_buyAfter(2, 0.1 ether), uint24(200_000));
        vm.roll(hook.launchBlock() + 99);
        assertEq(_buyAfter(2, 0.1 ether), uint24(134_334)); // 200,000 - 197,000 * 100 / 300
        vm.roll(hook.launchBlock() + 400);
        assertEq(_buyAfter(2, 0.1 ether), uint24(3000));
    }

    function testFuzz_fee_isMonotonicAndBounded(uint256 a, uint256 b) public {
        _launch();
        uint256 start = vm.getBlockNumber();
        a = bound(a, 0, 1000);
        b = bound(b, 0, 1000);
        (uint256 early, uint256 late) = a < b ? (a, b) : (b, a);
        vm.roll(start + early);
        uint24 feeEarly = hook.currentFee();
        vm.roll(start + late);
        uint24 feeLate = hook.currentFee();
        assertGe(feeEarly, feeLate);
        assertLe(feeEarly, 200_000);
        assertGe(feeLate, 3000);
        assertEq(feeEarly, early >= 300 ? 3000 : 200_000 - 197_000 * early / 300);
    }

    // --- average price -----------------------------------------------------------

    function test_meanTick_needs30MinutesOfHistory() public {
        _launch();
        assertEq(hook.meanTick(0), LAUNCH_TICK);
        uint32 launchTime = uint32(vm.getBlockTimestamp());
        vm.warp(vm.getBlockTimestamp() + 1799);
        vm.expectRevert(abi.encodeWithSelector(LaunchFeeHook.InsufficientHistory.selector, launchTime - 1, launchTime));
        hook.meanTick(1800);
        vm.warp(vm.getBlockTimestamp() + 1);
        assertEq(hook.meanTick(1800), LAUNCH_TICK);
    }

    function test_RevertWhen_askedBeforeLaunch() public {
        vm.expectRevert(LaunchFeeHook.NotLaunched.selector);
        hook.meanTick(1800);
    }

    function test_meanTick_weighsEachTickByTheTimeItHeld() public {
        _launch();
        _buyAfter(600, 1 ether);
        _buyAfter(600, 2 ether);
        _sellAfter(300, 500_000e18);
        vm.warp(vm.getBlockTimestamp() + 900);
        assertEq(hook.meanTick(1800), _referenceMean(1800));
        assertEq(hook.meanTick(2400), _referenceMean(2400));
        assertEq(hook.meanTick(100), _referenceMean(100));
    }

    function test_meanTick_resistsAManipulationInTheLastBlock() public {
        _launch();
        _buyAfter(1800, 0.5 ether);
        int24 before = hook.meanTick(1800);
        _buyAfter(2, 50 ether); // pushes the price far, one block before a buyback would run
        vm.warp(vm.getBlockTimestamp() + 2);
        int24 spot = _tick();
        int24 mean = hook.meanTick(1800);
        assertLt(spot, before - 198, "spot moved more than 2%");
        assertGt(mean, spot + 198, "the average barely moved, so a buyback would revert");
    }

    function test_meanTick_approximatesSwapsCloserThanTheSpacing() public {
        _launch();
        for (uint256 i; i < 60; ++i) {
            _buyAfter(4, 0.05 ether); // every other block, below the 30-second spacing
        }
        vm.warp(vm.getBlockTimestamp() + 1600); // 240 seconds of swaps, then a quiet period
        int24 mean = hook.meanTick(1800);
        int24 exact = _referenceMean(1800);
        assertApproxEqAbs(mean, exact, 20, "interpolation error stays within a few ticks");
    }

    function test_observations_wrapAroundTheRing() public {
        _launch();
        for (uint256 i; i < 200; ++i) {
            if (i % 2 == 0) _buyAfter(31, 0.02 ether);
            else _sellAfter(31, 1000e18);
        }
        assertEq(hook.observationCount(), 128);
        assertEq(hook.observationIndex(), 200 % 128);
        assertEq(hook.meanTick(1800), _referenceMean(1800));
        assertEq(hook.meanTick(3900), _referenceMean(3900));
        vm.expectRevert();
        hook.meanTick(4000); // older than the 128 kept observations
    }

    function test_update_onlyTheFirstSwapOfABlockCounts() public {
        _launch();
        _buyAfter(600, 1 ether);
        LaunchFeeHook.Observation memory first = hook.observation(hook.observationIndex());
        vm.prank(trader);
        swapper.buy{value: 1 ether}(key); // same block: moves the price but adds nothing to the sum yet
        LaunchFeeHook.Observation memory second = hook.observation(hook.observationIndex());
        assertEq(second.timestamp, first.timestamp);
        assertEq(second.tickCumulative, first.tickCumulative);
        assertEq(second.tickCumulative, int56(LAUNCH_TICK) * 600);
        changeTicks[changeTicks.length - 1] = _tick(); // the tick in force from this block on
        vm.warp(vm.getBlockTimestamp() + 1800);
        assertEq(hook.meanTick(1800), _referenceMean(1800));
    }

    /// @dev A TENAX price above 1 ETH means negative ticks; the average then rounds toward negative infinity.
    function test_meanTick_roundsNegativeAveragesDown() public {
        PoolLauncher otherLauncher = new PoolLauncher(poolManager, positionManager, tenax);
        address at = address(uint160(uint256(keccak256("negative hook")) & ~uint256(Hooks.ALL_HOOK_MASK)) | FLAGS);
        deployCodeTo(
            "LaunchFeeHook.sol:LaunchFeeHook", abi.encode(poolManager, address(otherLauncher), address(tenax)), at
        );
        hook = LaunchFeeHook(at);
        key.hooks = IHooks(at);
        tenax.transfer(address(otherLauncher), 1_000_000e18);
        otherLauncher.launch(key, -60_060, vault);
        _recordTick();

        _buyAfter(601, 0.001 ether);
        vm.warp(vm.getBlockTimestamp() + 1207);
        int24 mean = hook.meanTick(1807);
        assertLt(mean, 0);
        assertEq(mean, _referenceMean(1807));
    }

    /// @dev With swaps at least 30 seconds apart every update is kept, and the average is exact.
    function testFuzz_meanTick_matchesTheReference(uint256 seed, uint32 window) public {
        _launch();
        uint256 netBought;
        for (uint256 i; i < 12; ++i) {
            uint256 r = uint256(keccak256(abi.encode(seed, i)));
            uint256 gap = 30 + r % 600;
            if (r % 3 == 0 && netBought > 1000e18) {
                uint256 amount = netBought / 2;
                netBought -= amount;
                _sellAfter(gap, amount);
            } else {
                uint256 before = tenax.balanceOf(trader);
                _buyAfter(gap, 0.01 ether + (r >> 8) % 3 ether);
                netBought += tenax.balanceOf(trader) - before;
            }
        }
        vm.warp(vm.getBlockTimestamp() + (seed >> 128) % 1200);
        uint256 history = vm.getBlockTimestamp() - changeTimes[0];
        window = uint32(bound(window, 1, history));
        assertEq(hook.meanTick(window), _referenceMean(window));
    }
}
