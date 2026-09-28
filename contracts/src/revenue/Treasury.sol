// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SeasonRewards} from "../distribution/SeasonRewards.sol";
import {IBurnableERC20, VotingEscrow} from "../escrow/VotingEscrow.sol";
import {IPriceObserver} from "../interfaces/IPriceObserver.sol";
import {ISeasonTreasury} from "../interfaces/ISeasonTreasury.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @notice OP Stack predeploy that estimates the L1 data fee of a transaction.
interface IGasPriceOracle {
    function getL1FeeUpperBound(uint256 unsignedTxSize) external view returns (uint256);
}

/// @title Treasury
/// @notice Rule-based treasury with no withdrawal function (whitepaper section 7). It pays keepers, releases the
/// 20M TENAX reserve at a fixed rate per season and tops up season rewards while ETH revenue is below target.
/// @dev Keepers run protocol tasks through `execute`, which checks the task against a list fixed at deployment,
/// runs it, measures its gas and refunds it with a 50% margin, capped per call and by a monthly budget. The refund
/// is paid in WETH; when the treasury has no WETH for it, the keeper receives a fixed amount of TENAX from the
/// current season's reserve allowance, locked for 52 weeks.
///
/// Each season's allowance (1/60 of the reserve) first pays those TENAX keeper rewards. When the season closes,
/// `SeasonRewards` calls `settleSeason`: a top-up that shrinks as the season's ETH revenue approaches the target
/// goes to the season budget, and everything else is burned. The allowance never accumulates.
///
/// WETH above the keeper reserve buys back TENAX in the protocol's pool, at most once every 24 hours and up to a
/// cap per call, and the TENAX bought is burned in the same transaction. The buyback reverts if the pool price
/// deviates more than about 2% from its 30-minute average, and the swap itself cannot push the price further than
/// that, so nobody can profit from moving the price right before it.
contract Treasury is ISeasonTreasury, IUnlockCallback, ReentrancyGuardTransient {
    using SafeERC20 for IBurnableERC20;
    using SafeERC20 for IWETH;
    using StateLibrary for IPoolManager;

    struct Task {
        address target;
        bytes4 selector;
        uint64 minInterval;
    }

    struct KeeperParams {
        uint256 maxTip; // wei per gas above the base fee
        uint256 capPerCall; // WETH
        uint256 monthlyBudget; // WETH per 30-day period
        uint256 tenaxReward; // TENAX per task when no WETH is available
    }

    /// @notice TENAX reserve: 20,000,000 TENAX, released over 60 seasons.
    uint256 public constant RESERVE = 20_000_000e18;
    uint256 public constant ALLOWANCE_SEASONS = 60;
    uint256 public constant SEASON_ALLOWANCE = RESERVE / ALLOWANCE_SEASONS;

    /// @notice Keeper refund margin: gas cost times 1.5.
    uint256 public constant KEEPER_MARGIN_BPS = 15_000;

    /// @notice Gas spent outside the measured call: the base transaction, calldata and the payment itself.
    uint256 public constant GAS_OVERHEAD = 60_000;

    /// @notice Bytes added to the calldata length to estimate the size of the signed transaction.
    uint256 public constant TX_SIZE_OVERHEAD = 100;

    uint256 public constant BUDGET_PERIOD = 30 days;

    /// @notice The ETH reserve for keepers covers 90 days of the maximum budget.
    uint256 public constant RESERVE_PERIODS = 3;

    uint256 public constant KEEPER_LOCK = 52 weeks;

    uint256 public constant MAX_TIP_LIMIT = 1 gwei;
    uint256 public constant MIN_CAP_PER_CALL = 0.000_01 ether;
    uint256 public constant MAX_CAP_PER_CALL = 0.01 ether;
    uint256 public constant MIN_MONTHLY_BUDGET = 0.001 ether;
    uint256 public constant MAX_MONTHLY_BUDGET = 1 ether;
    uint256 public constant MAX_TENAX_REWARD = 2500e18;
    uint256 public constant MIN_REVENUE_TARGET = 0.01 ether;
    uint256 public constant MAX_REVENUE_TARGET = 10 ether;
    uint256 public constant MIN_BUYBACK_CAP = 0.001 ether;
    uint256 public constant MAX_BUYBACK_CAP = 10 ether;

    uint256 public constant BUYBACK_INTERVAL = 24 hours;

    /// @notice Window of the average price that guards buybacks.
    uint32 public constant TWAP_WINDOW = 30 minutes;

    /// @notice Largest distance from the average tick at which a buyback runs: 1.0001^198 is about 1.02.
    int24 public constant MAX_TICK_DEVIATION = 198;

    IGasPriceOracle public constant GAS_PRICE_ORACLE = IGasPriceOracle(0x420000000000000000000000000000000000000F);

    IBurnableERC20 public immutable token;
    IWETH public immutable weth;
    VotingEscrow public immutable escrow;
    address public immutable governance;
    uint256 public immutable deployedAt;
    address private immutable _initializer;

    SeasonRewards public seasonRewards;
    Task[] private _tasks;
    mapping(uint256 taskId => uint256 timestamp) public lastRun;

    KeeperParams private _keeperParams;

    /// @notice Revenue target T_ETH: season ETH revenue at which the top-up reaches zero.
    uint256 public revenueTarget;

    mapping(uint256 period => uint256 amount) public keeperSpent;

    /// @notice TENAX of each season's allowance already paid to keepers.
    mapping(uint256 season => uint256 amount) public allowanceUsed;

    /// @notice Next season whose allowance will be settled; every earlier one is settled.
    uint256 public nextSeasonToSettle;

    uint256 public totalKeeperEth;
    uint256 public totalKeeperTenax;
    uint256 public totalTopUps;
    uint256 public totalBurned;

    /// @notice Pool manager, pool and price observer used by buybacks; set once at launch.
    IPoolManager public poolManager;
    IPriceObserver public priceObserver;
    PoolKey private _poolKey;

    /// @notice Largest WETH amount a single buyback can spend.
    uint256 public buybackCap;
    uint256 public lastBuyback;
    uint256 public totalBuybackEth;
    uint256 public totalBuybackBurned;

    event Initialized(address seasonRewards, uint256 taskCount);
    event KeeperParamsUpdated(uint256 maxTip, uint256 capPerCall, uint256 monthlyBudget, uint256 tenaxReward);
    event RevenueTargetUpdated(uint256 target);
    event TaskExecuted(uint256 indexed taskId, address indexed keeper, uint256 gasUsed);
    event KeeperPaid(address indexed keeper, uint256 indexed taskId, uint256 eth, uint256 tenax);
    event SeasonSettled(uint256 indexed season, uint256 ethReceived, uint256 topUp, uint256 burned);
    event MarketInitialized(address poolManager, bytes32 poolId, address priceObserver);
    event BuybackCapUpdated(uint256 cap);
    event Buyback(uint256 ethSpent, uint256 tenaxBurned);

    error ZeroAddress();
    error TokenMismatch();
    error TreasuryMismatch();
    error NotInitializer();
    error AlreadyInitialized();
    error NotInitialized();
    error NotGovernance();
    error NotSeasonRewards();
    error OutOfBounds();
    error UnknownTask(uint256 taskId);
    error WrongSelector();
    error TooSoon(uint256 nextRun);
    error NotNextSeason(uint256 expected);
    error WrongPool();
    error MarketNotInitialized();
    error NoSurplus();
    error NotPoolManager();
    error PriceDeviation(int24 tick, int24 meanTick);
    error UnexpectedEth();

    /// @param governance_ Timelock allowed to adjust keeper parameters and the revenue target within bounds.
    constructor(IBurnableERC20 token_, IWETH weth_, VotingEscrow escrow_, address governance_) {
        if (
            address(token_) == address(0) || address(weth_) == address(0) || address(escrow_) == address(0)
                || governance_ == address(0)
        ) revert ZeroAddress();
        if (address(escrow_.token()) != address(token_)) revert TokenMismatch();
        token = token_;
        weth = weth_;
        escrow = escrow_;
        governance = governance_;
        deployedAt = block.timestamp;
        _initializer = msg.sender;
        _setKeeperParams(KeeperParams(0.01 gwei, 0.0005 ether, 0.02 ether, 250e18));
        _setRevenueTarget(0.07 ether);
        _setBuybackCap(0.05 ether);
    }

    /// @notice Native ETH only arrives from unwrapping WETH for a buyback.
    receive() external payable {
        if (msg.sender != address(weth)) revert UnexpectedEth();
    }

    // --- setup -------------------------------------------------------------------

    /// @notice Sets, once and forever, the season rewards contract and the list of paid keeper tasks.
    /// @dev Called by the deployer once every target exists; season rewards is deployed after the treasury.
    function initialize(SeasonRewards seasonRewards_, Task[] calldata tasks) external {
        if (msg.sender != _initializer) revert NotInitializer();
        if (address(seasonRewards) != address(0)) revert AlreadyInitialized();
        if (address(seasonRewards_) == address(0)) revert ZeroAddress();
        if (address(seasonRewards_.treasury()) != address(this)) revert TreasuryMismatch();
        seasonRewards = seasonRewards_;
        for (uint256 i; i < tasks.length; ++i) {
            // One-time setup: a zero target anywhere in the list aborts the whole initialization.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (tasks[i].target == address(0)) revert ZeroAddress();
            _tasks.push(tasks[i]);
        }
        emit Initialized(address(seasonRewards_), tasks.length);
    }

    /// @notice Sets, once and forever, the pool where buybacks happen and the observer of its average price.
    /// @dev Called by the launch script right after the pool is created. The pool pairs native ETH with TENAX.
    function initializeMarket(IPoolManager poolManager_, PoolKey calldata key, IPriceObserver observer) external {
        if (msg.sender != _initializer) revert NotInitializer();
        if (address(poolManager) != address(0)) revert AlreadyInitialized();
        if (address(poolManager_) == address(0) || address(observer) == address(0)) revert ZeroAddress();
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(token)) revert WrongPool();
        poolManager = poolManager_;
        priceObserver = observer;
        _poolKey = key;
        emit MarketInitialized(address(poolManager_), PoolId.unwrap(key.toId()), address(observer));
    }

    // --- governance --------------------------------------------------------------

    function setKeeperParams(KeeperParams calldata params) external {
        if (msg.sender != governance) revert NotGovernance();
        _setKeeperParams(params);
    }

    function setRevenueTarget(uint256 target) external {
        if (msg.sender != governance) revert NotGovernance();
        _setRevenueTarget(target);
    }

    function setBuybackCap(uint256 cap) external {
        if (msg.sender != governance) revert NotGovernance();
        _setBuybackCap(cap);
    }

    // --- buyback -----------------------------------------------------------------

    /// @notice Spends the WETH above the keeper reserve, up to the cap, buying TENAX in the protocol's pool and
    /// burning it. Anyone can call it, at most once every 24 hours; it also runs as a paid keeper task.
    /// @dev Not guarded against reentrancy because `execute` calls it on this contract; all state is written before
    /// the pool manager is called, and the pool manager only calls back `unlockCallback`.
    function buyback() external {
        if (address(poolManager) == address(0)) revert MarketNotInitialized();
        uint256 nextBuyback = lastBuyback + BUYBACK_INTERVAL;
        if (lastBuyback != 0 && block.timestamp < nextBuyback) revert TooSoon(nextBuyback);
        uint256 balance = weth.balanceOf(address(this));
        uint256 reserve = ethReserveTarget();
        if (balance <= reserve) revert NoSurplus();
        uint256 amount = balance - reserve;
        if (amount > buybackCap) amount = buybackCap;
        lastBuyback = block.timestamp;

        weth.withdraw(amount);
        (uint256 spent, uint256 bought) = abi.decode(poolManager.unlock(abi.encode(amount)), (uint256, uint256));
        if (spent < amount) weth.deposit{value: amount - spent}();
        totalBuybackEth += spent;
        totalBuybackBurned += bought;
        // The amounts come back from the pool manager; it only calls `unlockCallback`, which writes no state.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Buyback(spent, bought);
        if (bought != 0) token.burn(bought);
    }

    /// @notice Swap step of a buyback, run by the pool manager inside `unlock`.
    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        IPoolManager manager = poolManager;
        if (msg.sender != address(manager)) revert NotPoolManager();
        uint256 amount = abi.decode(data, (uint256));
        PoolKey memory key = _poolKey;

        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        int24 mean = priceObserver.meanTick(TWAP_WINDOW);

        // Buying TENAX with ETH moves the tick down; the swap stops once it is 2% below the average. The spot price
        // must sit within 2% of the average: at most that far above it, and strictly above the lower limit, so the
        // swap has room to run.
        int24 limitTick = mean - MAX_TICK_DEVIATION;
        uint160 limit =
            limitTick <= TickMath.MIN_TICK ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.getSqrtPriceAtTick(limitTick);
        if (tick > mean + MAX_TICK_DEVIATION || price <= limit) revert PriceDeviation(tick, mean);
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: true, amountSpecified: -SafeCast.toInt256(amount), sqrtPriceLimitX96: limit
            }),
            ""
        );
        // An exact-input ETH to TENAX swap owes ETH (negative amount0) and pays TENAX (positive amount1).
        uint256 spent = SafeCast.toUint256(-int256(delta.amount0()));
        uint256 bought = SafeCast.toUint256(int256(delta.amount1()));
        // The amount paid is exactly `spent`, sent as value.
        // forge-lint: disable-next-line(unused-return)
        if (spent != 0) manager.settle{value: spent}();
        if (bought != 0) manager.take(key.currency1, address(this), bought);
        return abi.encode(spent, bought);
    }

    // --- keepers -----------------------------------------------------------------

    /// @notice Runs keeper task `taskId` with `data` as calldata and pays the caller for it.
    /// @dev The call must succeed; failures revert the whole transaction, so keepers are only paid for work done.
    function execute(uint256 taskId, bytes calldata data) external nonReentrant {
        if (address(seasonRewards) == address(0)) revert NotInitialized();
        if (taskId >= _tasks.length) revert UnknownTask(taskId);
        Task memory entry = _tasks[taskId];
        if (data.length < 4 || bytes4(data[:4]) != entry.selector) revert WrongSelector();
        uint256 nextRun = lastRun[taskId] + entry.minInterval;
        if (lastRun[taskId] != 0 && block.timestamp < nextRun) revert TooSoon(nextRun);
        lastRun[taskId] = block.timestamp;

        uint256 gasStart = gasleft();
        Address.functionCall(entry.target, data);
        uint256 gasUsed = gasStart - gasleft() + GAS_OVERHEAD;
        // The event reports the gas of the task, so it can only follow it. Targets are fixed protocol contracts
        // and `execute` cannot be reentered.
        // forge-lint: disable-next-line(reentrancy-events)
        emit TaskExecuted(taskId, msg.sender, gasUsed);

        _payKeeper(msg.sender, taskId, gasUsed, data.length);
    }

    // --- seasons -----------------------------------------------------------------

    /// @inheritdoc ISeasonTreasury
    function settleSeason(uint256 season, uint256 ethReceived, bool hasParticipants) external returns (uint256 topUp) {
        if (msg.sender != address(seasonRewards)) revert NotSeasonRewards();
        if (season != nextSeasonToSettle) revert NotNextSeason(nextSeasonToSettle);
        nextSeasonToSettle = season + 1;

        uint256 available = allowanceOf(season) - allowanceUsed[season];
        if (hasParticipants && ethReceived < revenueTarget) {
            topUp = available * (revenueTarget - ethReceived) / revenueTarget;
        }
        uint256 burned = available - topUp;
        allowanceUsed[season] += available;
        totalTopUps += topUp;
        totalBurned += burned;
        emit SeasonSettled(season, ethReceived, topUp, burned);

        if (topUp != 0) token.safeTransfer(msg.sender, topUp);
        if (burned != 0) token.burn(burned);
    }

    // --- views -------------------------------------------------------------------

    /// @notice TENAX released for `season`: 1/60 of the reserve for seasons 0 to 59, the last one taking the
    /// rounding remainder, and nothing afterwards.
    function allowanceOf(uint256 season) public pure returns (uint256) {
        if (season + 1 < ALLOWANCE_SEASONS) return SEASON_ALLOWANCE;
        if (season + 1 == ALLOWANCE_SEASONS) return RESERVE - SEASON_ALLOWANCE * (ALLOWANCE_SEASONS - 1);
        return 0;
    }

    /// @notice WETH kept for keepers: 90 days of the maximum monthly budget. Only the surplus can be spent on
    /// buybacks.
    function ethReserveTarget() public view returns (uint256) {
        return _keeperParams.monthlyBudget * RESERVE_PERIODS;
    }

    function poolKey() external view returns (PoolKey memory) {
        return _poolKey;
    }

    function keeperParams() external view returns (KeeperParams memory) {
        return _keeperParams;
    }

    function task(uint256 taskId) external view returns (Task memory) {
        return _tasks[taskId];
    }

    function taskCount() external view returns (uint256) {
        return _tasks.length;
    }

    /// @notice Current 30-day keeper budget period.
    function currentPeriod() public view returns (uint256) {
        return (block.timestamp - deployedAt) / BUDGET_PERIOD;
    }

    /// @notice Refund owed for `gasUsed` at the current gas price with `txSize` bytes of calldata, before caps
    /// by budget.
    function keeperReward(uint256 gasUsed, uint256 txSize) public view returns (uint256) {
        KeeperParams memory params = _keeperParams;
        uint256 gasPrice = tx.gasprice;
        uint256 maxPrice = block.basefee + params.maxTip;
        if (gasPrice > maxPrice) gasPrice = maxPrice;
        uint256 reward = (gasUsed * gasPrice + _l1Cost(txSize)) * KEEPER_MARGIN_BPS / 10_000;
        return reward < params.capPerCall ? reward : params.capPerCall;
    }

    // --- internals ---------------------------------------------------------------

    function _payKeeper(address keeper, uint256 taskId, uint256 gasUsed, uint256 dataLength) private {
        uint256 reward = keeperReward(gasUsed, dataLength + TX_SIZE_OVERHEAD);
        if (reward == 0) return;
        uint256 period = currentPeriod();
        if (keeperSpent[period] + reward > _keeperParams.monthlyBudget) return;

        if (weth.balanceOf(address(this)) >= reward) {
            keeperSpent[period] += reward;
            totalKeeperEth += reward;
            // The preceding external call is a WETH balance read.
            // forge-lint: disable-next-line(reentrancy-events)
            emit KeeperPaid(keeper, taskId, reward, 0);
            weth.safeTransfer(keeper, reward);
            return;
        }
        _payKeeperInTenax(keeper, taskId);
    }

    /// @dev Pays the fixed TENAX reward from the running season's allowance, locked. A keeper whose own expired
    /// lock blocks the delivery is simply not paid in TENAX.
    function _payKeeperInTenax(address keeper, uint256 taskId) private {
        // A season closes only after it ends, so the season in progress is never one already settled.
        uint256 season = seasonRewards.currentSeason();
        uint256 available = allowanceOf(season) - allowanceUsed[season];
        uint256 amount = _keeperParams.tenaxReward < available ? _keeperParams.tenaxReward : available;
        if (amount == 0) return;

        allowanceUsed[season] += amount;
        totalKeeperTenax += amount;
        token.forceApprove(address(escrow), amount);
        // The escrow is an immutable protocol contract and `execute` cannot be reentered; a failed delivery only
        // rolls back the accounting made above.
        // forge-lint: disable-next-line(reentrancy-no-eth)
        try escrow.createLockFor(keeper, amount, KEEPER_LOCK) {
            // forge-lint: disable-next-line(reentrancy-events)
            emit KeeperPaid(keeper, taskId, 0, amount);
        } catch {
            allowanceUsed[season] -= amount;
            totalKeeperTenax -= amount;
            token.forceApprove(address(escrow), 0);
        }
    }

    function _l1Cost(uint256 txSize) private view returns (uint256) {
        if (address(GAS_PRICE_ORACLE).code.length == 0) return 0;
        return GAS_PRICE_ORACLE.getL1FeeUpperBound(txSize);
    }

    function _setKeeperParams(KeeperParams memory params) private {
        if (
            params.maxTip > MAX_TIP_LIMIT || params.capPerCall < MIN_CAP_PER_CALL
                || params.capPerCall > MAX_CAP_PER_CALL || params.monthlyBudget < MIN_MONTHLY_BUDGET
                || params.monthlyBudget > MAX_MONTHLY_BUDGET || params.tenaxReward > MAX_TENAX_REWARD
        ) revert OutOfBounds();
        _keeperParams = params;
        emit KeeperParamsUpdated(params.maxTip, params.capPerCall, params.monthlyBudget, params.tenaxReward);
    }

    function _setBuybackCap(uint256 cap) private {
        if (cap < MIN_BUYBACK_CAP || cap > MAX_BUYBACK_CAP) revert OutOfBounds();
        buybackCap = cap;
        emit BuybackCapUpdated(cap);
    }

    function _setRevenueTarget(uint256 target) private {
        if (target < MIN_REVENUE_TARGET || target > MAX_REVENUE_TARGET) revert OutOfBounds();
        revenueTarget = target;
        emit RevenueTargetUpdated(target);
    }
}
