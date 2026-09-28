// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceObserver} from "../interfaces/IPriceObserver.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {BaseHook} from "@uniswap/v4-periphery/src/utils/BaseHook.sol";

/// @title LaunchFeeHook
/// @notice Hook of the protocol's ETH / TENAX pool (whitepaper section 5.1). It restricts the pool's creation to
/// the launcher, charges a launch fee that decays from 20% to the permanent 0.3% over 300 blocks, and keeps the
/// time-weighted average tick that guards the treasury's buybacks.
/// @dev The hook serves exactly one pool: only the launcher can initialize a pool with it, and only once.
///
/// The average price follows the Uniswap v3 oracle: before the first swap of each block, the tick that held since
/// the last update is added to a cumulative sum weighted by time. The sum is copied into a ring buffer of 128
/// observations at most once every 30 seconds, which covers at least 64 minutes. The cumulative value at a past
/// time is exact when no swap happened between the surrounding observations and linearly interpolated otherwise.
contract LaunchFeeHook is BaseHook, IPriceObserver {
    using StateLibrary for IPoolManager;

    struct Observation {
        uint32 timestamp;
        int56 tickCumulative;
    }

    /// @notice Launch fee in hundredths of a basis point: 20%.
    uint24 public constant INITIAL_FEE = 200_000;

    /// @notice Permanent fee: 0.3%.
    uint24 public constant FINAL_FEE = 3000;

    /// @notice Blocks over which the launch fee decays, about 10 minutes of Base blocks.
    uint256 public constant DECAY_BLOCKS = 300;

    uint256 public constant CARDINALITY = 128;
    uint32 public constant OBSERVATION_SPACING = 30;

    address public immutable launcher;
    address public immutable token;

    PoolId public poolId;
    uint64 public launchBlock;
    bool public launched;

    /// @dev Time-weighted tick sum at the last update.
    Observation private _accumulator;
    Observation[CARDINALITY] private _observations;
    uint16 public observationIndex;
    uint16 public observationCount;

    event Launched(bytes32 indexed poolId, uint256 launchBlock);

    error ZeroAddress();
    error NotLauncher(address sender);
    error AlreadyLaunched();
    error WrongPool();
    error NotLaunched();
    error InsufficientHistory(uint32 target, uint32 oldest);

    constructor(IPoolManager manager, address launcher_, address token_) BaseHook(manager) {
        if (launcher_ == address(0) || token_ == address(0)) revert ZeroAddress();
        launcher = launcher_;
        token = token_;
    }

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: true,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // --- views -------------------------------------------------------------------

    /// @notice Fee charged on swaps in the current block, in hundredths of a basis point.
    function currentFee() public view returns (uint24) {
        uint256 elapsed = block.number - launchBlock;
        if (elapsed >= DECAY_BLOCKS) return FINAL_FEE;
        // The decay is at most 197,000 over 300 blocks, so the result fits in 24 bits.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint24(INITIAL_FEE - (uint256(INITIAL_FEE - FINAL_FEE) * elapsed) / DECAY_BLOCKS);
    }

    /// @inheritdoc IPriceObserver
    function meanTick(uint32 window) external view returns (int24) {
        if (!launched) revert NotLaunched();
        int24 tick = _currentTick();
        if (window == 0) return tick;
        // Timestamps fit in 32 bits until 2106, like the rest of the oracle.
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 now_ = uint32(block.timestamp);
        int56 delta = _cumulativeAt(now_, tick) - _cumulativeAt(now_ - window, tick);
        int56 mean = delta / int56(uint56(window));
        // Round toward negative infinity, like Uniswap's oracle library.
        if (delta < 0 && delta % int56(uint56(window)) != 0) --mean;
        // The mean of ticks within the valid range is itself within it.
        // forge-lint: disable-next-line(unsafe-typecast)
        return int24(mean);
    }

    function observation(uint256 index) external view returns (Observation memory) {
        return _observations[index];
    }

    // --- hooks -------------------------------------------------------------------

    function _beforeInitialize(address sender, PoolKey calldata key, uint160) internal override returns (bytes4) {
        if (sender != launcher) revert NotLauncher(sender);
        if (launched) revert AlreadyLaunched();
        if (
            key.fee != LPFeeLibrary.DYNAMIC_FEE_FLAG || !key.currency0.isAddressZero()
                || Currency.unwrap(key.currency1) != token
        ) revert WrongPool();
        launched = true;
        poolId = key.toId();
        return this.beforeInitialize.selector;
    }

    function _afterInitialize(address, PoolKey calldata key, uint160, int24) internal override returns (bytes4) {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 now_ = uint32(block.timestamp);
        _accumulator = Observation(now_, 0);
        _observations[0] = Observation(now_, 0);
        observationCount = 1;
        // forge-lint: disable-next-line(unsafe-typecast)
        launchBlock = uint64(block.number);
        emit Launched(PoolId.unwrap(key.toId()), block.number);
        return this.afterInitialize.selector;
    }

    /// @dev Only the launched pool can call it: no other pool can be initialized with this hook.
    function _beforeSwap(address, PoolKey calldata, IPoolManager.SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _update();
        return
            (this.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, currentFee() | LPFeeLibrary.OVERRIDE_FEE_FLAG);
    }

    // --- oracle ------------------------------------------------------------------

    /// @dev Adds the tick that held since the last update, before the first swap of the block moves it.
    function _update() private {
        // forge-lint: disable-next-line(unsafe-typecast)
        uint32 now_ = uint32(block.timestamp);
        Observation memory acc = _accumulator;
        if (acc.timestamp == now_) return;
        acc.tickCumulative += int56(_currentTick()) * int56(uint56(now_ - acc.timestamp));
        acc.timestamp = now_;
        _accumulator = acc;

        uint16 index = observationIndex;
        if (now_ - _observations[index].timestamp < OBSERVATION_SPACING) return;
        // forge-lint: disable-next-line(unsafe-typecast)
        index = uint16((index + 1) % CARDINALITY);
        _observations[index] = acc;
        // Observations are readable through views; an event on every swap block would only cost traders gas.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        observationIndex = index;
        // forge-lint: disable-next-line(missing-events-arithmetic)
        if (observationCount < CARDINALITY) ++observationCount;
    }

    /// @dev Cumulative tick at `target`, which must not be in the future.
    function _cumulativeAt(uint32 target, int24 tick) private view returns (int56) {
        Observation memory acc = _accumulator;
        if (target >= acc.timestamp) return acc.tickCumulative + int56(tick) * int56(uint56(target - acc.timestamp));

        uint256 count = observationCount;
        uint256 oldest = count < CARDINALITY ? 0 : (observationIndex + 1) % CARDINALITY;
        Observation memory first = _observations[oldest];
        if (target < first.timestamp) revert InsufficientHistory(target, first.timestamp);

        // Newest observation at or before the target, by binary search over positions from oldest to newest.
        uint256 low = 0;
        uint256 high = count - 1;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (_observations[(oldest + mid) % CARDINALITY].timestamp <= target) low = mid;
            else high = mid - 1;
        }
        Observation memory before = _observations[(oldest + low) % CARDINALITY];
        if (before.timestamp == target) return before.tickCumulative;
        Observation memory next = low + 1 < count ? _observations[(oldest + low + 1) % CARDINALITY] : acc;
        return before.tickCumulative + (next.tickCumulative - before.tickCumulative)
            * int56(uint56(target - before.timestamp)) / int56(uint56(next.timestamp - before.timestamp));
    }

    function _currentTick() private view returns (int24 tick) {
        (, tick,,) = poolManager.getSlot0(poolId);
    }
}
