// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EscrowMath} from "./EscrowMath.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {IERC6372} from "@openzeppelin/contracts/interfaces/IERC6372.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Token locked in the escrow; burning is used for early exit penalties.
interface IBurnableERC20 is IERC20 {
    function burn(uint256 value) external;
}

/// @title VotingEscrow
/// @notice Locks TENAX for 1 week to 2 years in exchange for veTENAX, a non-transferable balance that decays
/// linearly to zero at unlock and grants revenue share, forecasting access and voting power.
/// @dev Adapted from Curve's VotingEscrow. Balances are tracked as slope/bias checkpoints with weekly slope
/// changes, so any balance or the total supply can be read at any past timestamp. The clock is the block
/// timestamp (ERC-6372) and the contract exposes IVotes for the Governor, without delegation.
///
/// Tokens delivered by emission and airdrop contracts through `createLockFor` are tracked in `granted` and can
/// never leave before the lock expires. The voluntary portion can exit early through `withdrawEarly`, paying a
/// penalty of up to 50% that is burned.
contract VotingEscrow is IVotes, IERC6372, ReentrancyGuardTransient {
    using SafeERC20 for IBurnableERC20;
    using SafeCast for uint256;
    using SafeCast for int256;

    struct LockedBalance {
        uint128 amount; // total locked, voluntary plus granted
        uint128 granted; // portion delivered by distributors, which cannot exit early
        uint64 end; // unlock timestamp, rounded down to the week
    }

    struct Point {
        int128 bias;
        int128 slope;
        uint64 ts;
    }

    string public constant name = "Vote-escrowed TENAX";
    string public constant symbol = "veTENAX";
    uint8 public constant decimals = 18;

    uint256 public constant WEEK = EscrowMath.WEEK;
    uint256 public constant MAX_LOCK = EscrowMath.MAX_LOCK;
    uint256 public constant MIN_LOCK = EscrowMath.MIN_LOCK;

    /// @dev Weeks processed per checkpoint; the global history must be advanced at least once per ~4.9 years.
    uint256 private constant MAX_WEEKS_PER_CHECKPOINT = 255;

    IBurnableERC20 public immutable token;
    address private immutable _initializer;

    bool public distributorsInitialized;
    mapping(address distributor => bool authorized) public isDistributor;

    /// @notice Total TENAX held in locks.
    uint256 public supply;

    uint256 public epoch;
    mapping(uint256 epoch => Point) public pointHistory;
    mapping(address user => mapping(uint256 userEpoch => Point)) public userPointHistory;
    mapping(address user => uint256 userEpoch) public userPointEpoch;
    mapping(uint256 timestamp => int128 slopeDelta) public slopeChanges;

    mapping(address user => LockedBalance) private _locked;

    event DistributorsInitialized(address[] distributors);
    event Locked(address indexed user, address indexed payer, uint256 amount, bool granted, uint256 unlockTime);
    event UnlockTimeIncreased(address indexed user, uint256 unlockTime);
    event Withdrawn(address indexed user, uint256 amount);
    event WithdrawnEarly(address indexed user, uint256 returned, uint256 penalty);
    event SupplyUpdated(uint256 previousSupply, uint256 newSupply);

    error NotInitializer();
    error DistributorsAlreadyInitialized();
    error NotDistributor(address caller);
    error ZeroAddress();
    error ZeroAmount();
    error LockAlreadyExists();
    error NoLock();
    error LockExpired();
    error LockNotExpired(uint256 unlockTime);
    error UnlockTimeTooSoon(uint256 unlockTime);
    error UnlockTimeTooLate(uint256 unlockTime);
    error UnlockTimeNotIncreased(uint256 unlockTime);
    error InvalidLockDuration(uint256 duration);
    error NoVoluntaryBalance();
    error DelegationDisabled();
    error ERC5805FutureLookup(uint256 timepoint, uint48 clock);
    error CheckpointRequired();

    constructor(IBurnableERC20 token_) {
        if (address(token_) == address(0)) revert ZeroAddress();
        token = token_;
        _initializer = msg.sender;
        pointHistory[0].ts = block.timestamp.toUint64();
    }

    // --- setup -----------------------------------------------------------------

    /// @notice Sets, once and forever, the contracts allowed to deliver locked tokens (emissions and airdrop).
    /// @dev Called by the deployer during deployment; there is no way to change the list afterwards.
    function initializeDistributors(address[] calldata distributors) external {
        if (msg.sender != _initializer) revert NotInitializer();
        if (distributorsInitialized) revert DistributorsAlreadyInitialized();
        distributorsInitialized = true;
        for (uint256 i; i < distributors.length; ++i) {
            // One-time setup: a zero address anywhere in the list aborts the whole initialization.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (distributors[i] == address(0)) revert ZeroAddress();
            // The whole list is emitted in DistributorsInitialized below.
            // forge-lint: disable-next-line(missing-events-access-control)
            isDistributor[distributors[i]] = true;
        }
        emit DistributorsInitialized(distributors);
    }

    // --- locks -----------------------------------------------------------------

    /// @notice Current lock of `user`.
    function locked(address user) external view returns (uint256 amount, uint256 granted, uint256 end) {
        LockedBalance memory lock = _locked[user];
        return (lock.amount, lock.granted, lock.end);
    }

    /// @notice Locks `amount` until `unlockTime`, rounded down to the week.
    function createLock(uint256 amount, uint256 unlockTime) external nonReentrant {
        LockedBalance memory lock = _locked[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (lock.amount != 0) revert LockAlreadyExists();
        uint256 end = EscrowMath.roundDownToWeek(unlockTime);
        _validateNewEnd(end, unlockTime);
        _deposit(msg.sender, msg.sender, amount, false, end, lock);
    }

    /// @notice Adds `amount` to an active lock without changing its unlock time.
    function increaseAmount(uint256 amount) external nonReentrant {
        LockedBalance memory lock = _locked[msg.sender];
        if (amount == 0) revert ZeroAmount();
        if (lock.amount == 0) revert NoLock();
        if (lock.end <= block.timestamp) revert LockExpired();
        _deposit(msg.sender, msg.sender, amount, false, lock.end, lock);
    }

    /// @notice Extends an active lock to `unlockTime`, rounded down to the week.
    function increaseUnlockTime(uint256 unlockTime) external nonReentrant {
        LockedBalance memory lock = _locked[msg.sender];
        if (lock.amount == 0) revert NoLock();
        if (lock.end <= block.timestamp) revert LockExpired();
        uint256 end = EscrowMath.roundDownToWeek(unlockTime);
        if (end <= lock.end) revert UnlockTimeNotIncreased(unlockTime);
        if (end > block.timestamp + MAX_LOCK) revert UnlockTimeTooLate(unlockTime);
        _deposit(msg.sender, msg.sender, 0, false, end, lock);
        emit UnlockTimeIncreased(msg.sender, end);
    }

    /// @notice Locks `amount` for `beneficiary`, paid by the calling distributor, for at least `lockDuration`.
    /// @dev Only authorized distributors can call it, and only as part of a claim triggered by the beneficiary.
    /// An active lock receives the amount and is extended to the required duration if needed, never shortened.
    /// Durations are measured in whole weeks: the unlock time is rounded down to the week, like every lock.
    function createLockFor(address beneficiary, uint256 amount, uint256 lockDuration) external nonReentrant {
        if (!isDistributor[msg.sender]) revert NotDistributor(msg.sender);
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (lockDuration < MIN_LOCK || lockDuration > MAX_LOCK) revert InvalidLockDuration(lockDuration);

        LockedBalance memory lock = _locked[beneficiary];
        if (lock.amount != 0 && lock.end <= block.timestamp) revert LockExpired();

        uint256 requiredEnd = EscrowMath.roundDownToWeek(block.timestamp + lockDuration);
        uint256 end = requiredEnd > lock.end ? requiredEnd : lock.end;
        _deposit(beneficiary, msg.sender, amount, true, end, lock);
    }

    /// @notice Withdraws the whole lock after it expires.
    function withdraw() external nonReentrant {
        LockedBalance memory lock = _locked[msg.sender];
        if (lock.amount == 0) revert NoLock();
        if (block.timestamp < lock.end) revert LockNotExpired(lock.end);

        uint256 amount = lock.amount;
        _locked[msg.sender] = LockedBalance(0, 0, 0);
        uint256 previousSupply = supply;
        supply = previousSupply - amount;
        _checkpoint(msg.sender, lock, LockedBalance(0, 0, 0));
        emit Withdrawn(msg.sender, amount);
        emit SupplyUpdated(previousSupply, previousSupply - amount);

        token.safeTransfer(msg.sender, amount);
    }

    /// @notice Withdraws the voluntary portion of an active lock before it expires, burning a penalty of
    /// min(time left / 104 weeks, 50%). Tokens delivered by distributors stay locked until the unlock time.
    function withdrawEarly() external nonReentrant {
        LockedBalance memory lock = _locked[msg.sender];
        if (lock.amount == 0) revert NoLock();
        if (lock.end <= block.timestamp) revert LockExpired();
        uint256 voluntary = lock.amount - lock.granted;
        if (voluntary == 0) revert NoVoluntaryBalance();

        uint256 penalty = EscrowMath.earlyExitPenalty(voluntary, lock.end - block.timestamp);
        LockedBalance memory remaining =
            lock.granted == 0 ? LockedBalance(0, 0, 0) : LockedBalance(lock.granted, lock.granted, lock.end);
        _locked[msg.sender] = remaining;
        uint256 previousSupply = supply;
        supply = previousSupply - voluntary;
        _checkpoint(msg.sender, lock, remaining);
        emit WithdrawnEarly(msg.sender, voluntary - penalty, penalty);
        emit SupplyUpdated(previousSupply, previousSupply - voluntary);

        token.burn(penalty);
        token.safeTransfer(msg.sender, voluntary - penalty);
    }

    /// @notice Advances the global history up to 255 weeks. Anyone can call it; only needed if nobody has
    /// interacted with the escrow for years.
    function checkpoint() external {
        _checkpoint(address(0), LockedBalance(0, 0, 0), LockedBalance(0, 0, 0));
    }

    // --- balances ----------------------------------------------------------------

    /// @notice Current veTENAX balance of `user`.
    function balanceOf(address user) public view returns (uint256) {
        return balanceOfAt(user, block.timestamp);
    }

    /// @notice veTENAX balance of `user` at `timestamp`.
    function balanceOfAt(address user, uint256 timestamp) public view returns (uint256) {
        uint256 userEpoch = _findUserEpoch(user, timestamp);
        if (userEpoch == 0) return 0;
        Point memory point = userPointHistory[user][userEpoch];
        int256 bias = int256(point.bias) - int256(point.slope) * (timestamp - point.ts).toInt256();
        return bias > 0 ? bias.toUint256() : 0;
    }

    /// @notice Current total veTENAX.
    function totalSupply() public view returns (uint256) {
        return totalSupplyAt(block.timestamp);
    }

    /// @notice Total veTENAX at `timestamp`.
    function totalSupplyAt(uint256 timestamp) public view returns (uint256) {
        uint256 globalEpoch = _findEpoch(timestamp);
        Point memory point = pointHistory[globalEpoch];
        if (point.ts > timestamp) return 0;
        return _supplyAt(point, timestamp);
    }

    // --- IVotes and ERC-6372 -----------------------------------------------------

    /// @inheritdoc IERC6372
    function clock() public view returns (uint48) {
        return block.timestamp.toUint48();
    }

    /// @inheritdoc IERC6372
    // forge-lint: disable-next-line(mixed-case-function)
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=timestamp";
    }

    /// @inheritdoc IVotes
    function getVotes(address account) external view returns (uint256) {
        return balanceOf(account);
    }

    /// @inheritdoc IVotes
    function getPastVotes(address account, uint256 timepoint) external view returns (uint256) {
        _requirePast(timepoint);
        return balanceOfAt(account, timepoint);
    }

    /// @inheritdoc IVotes
    function getPastTotalSupply(uint256 timepoint) external view returns (uint256) {
        _requirePast(timepoint);
        return totalSupplyAt(timepoint);
    }

    /// @notice Every account votes with its own balance; delegation is not supported.
    function delegates(address account) external pure returns (address) {
        return account;
    }

    /// @notice Delegation is not supported.
    function delegate(address) external pure {
        revert DelegationDisabled();
    }

    /// @notice Delegation is not supported.
    function delegateBySig(address, uint256, uint256, uint8, bytes32, bytes32) external pure {
        revert DelegationDisabled();
    }

    // --- internals ---------------------------------------------------------------

    function _validateNewEnd(uint256 end, uint256 requested) private view {
        if (end < block.timestamp + MIN_LOCK) revert UnlockTimeTooSoon(requested);
        if (end > block.timestamp + MAX_LOCK) revert UnlockTimeTooLate(requested);
    }

    function _deposit(
        address user,
        address payer,
        uint256 amount,
        bool granted,
        uint256 end,
        LockedBalance memory oldLock
    ) private {
        LockedBalance memory newLock = LockedBalance({
            amount: (oldLock.amount + amount).toUint128(),
            granted: (granted ? oldLock.granted + amount : oldLock.granted).toUint128(),
            end: end.toUint64()
        });
        _locked[user] = newLock;
        uint256 previousSupply = supply;
        // SupplyUpdated is emitted below whenever the supply actually changes.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        supply = previousSupply + amount;
        _checkpoint(user, oldLock, newLock);

        if (amount != 0) {
            emit Locked(user, payer, amount, granted, end);
            emit SupplyUpdated(previousSupply, previousSupply + amount);
            token.safeTransferFrom(payer, address(this), amount);
        }
    }

    /// @dev Records a user's lock change and advances the global history, applying weekly slope changes.
    function _checkpoint(address user, LockedBalance memory oldLock, LockedBalance memory newLock) private {
        Point memory userOld = Point(0, 0, 0);
        Point memory userNew = Point(0, 0, 0);
        int128 oldSlopeDelta = 0;
        int128 newSlopeDelta = 0;

        if (user != address(0)) {
            if (oldLock.end > block.timestamp && oldLock.amount > 0) {
                userOld.slope = EscrowMath.slope(oldLock.amount).toInt256().toInt128();
                userOld.bias = userOld.slope * (oldLock.end - block.timestamp).toInt256().toInt128();
            }
            if (newLock.end > block.timestamp && newLock.amount > 0) {
                userNew.slope = EscrowMath.slope(newLock.amount).toInt256().toInt128();
                userNew.bias = userNew.slope * (newLock.end - block.timestamp).toInt256().toInt128();
            }
            oldSlopeDelta = slopeChanges[oldLock.end];
            if (newLock.end != 0) {
                newSlopeDelta = newLock.end == oldLock.end ? oldSlopeDelta : slopeChanges[newLock.end];
            }
        }

        uint256 globalEpoch = epoch;
        Point memory lastPoint = pointHistory[globalEpoch];
        uint256 lastCheckpoint = lastPoint.ts;

        // Walk the global point forward week by week, applying scheduled slope changes.
        uint256 weekTime = EscrowMath.roundDownToWeek(lastCheckpoint);
        for (uint256 i; i < MAX_WEEKS_PER_CHECKPOINT; ++i) {
            weekTime += WEEK;
            int128 slopeDelta = 0;
            if (weekTime > block.timestamp) {
                weekTime = block.timestamp;
            } else {
                slopeDelta = slopeChanges[weekTime];
            }
            lastPoint.bias -= lastPoint.slope * (weekTime - lastCheckpoint).toInt256().toInt128();
            lastPoint.slope += slopeDelta;
            if (lastPoint.bias < 0) lastPoint.bias = 0;
            if (lastPoint.slope < 0) lastPoint.slope = 0;
            lastCheckpoint = weekTime;
            lastPoint.ts = weekTime.toUint64();
            ++globalEpoch;
            if (weekTime == block.timestamp) break;
            pointHistory[globalEpoch] = lastPoint;
        }

        if (user != address(0)) {
            // A user change can only be applied once the global history has caught up with the present.
            if (lastPoint.ts != block.timestamp) revert CheckpointRequired();
            lastPoint.slope += userNew.slope - userOld.slope;
            lastPoint.bias += userNew.bias - userOld.bias;
            if (lastPoint.slope < 0) lastPoint.slope = 0;
            if (lastPoint.bias < 0) lastPoint.bias = 0;
        }

        // Epochs are an internal index; every change is visible through the lock events.
        // forge-lint: disable-next-line(missing-events-arithmetic)
        epoch = globalEpoch;
        pointHistory[globalEpoch] = lastPoint;

        if (user != address(0)) {
            // Schedule when this lock's slope stops counting, replacing the old schedule.
            if (oldLock.end > block.timestamp) {
                oldSlopeDelta += userOld.slope;
                if (newLock.end == oldLock.end) oldSlopeDelta -= userNew.slope;
                slopeChanges[oldLock.end] = oldSlopeDelta;
            }
            if (newLock.end > block.timestamp && newLock.end > oldLock.end) {
                newSlopeDelta -= userNew.slope;
                slopeChanges[newLock.end] = newSlopeDelta;
            }

            uint256 userEpoch = userPointEpoch[user] + 1;
            userPointEpoch[user] = userEpoch;
            userNew.ts = block.timestamp.toUint64();
            userPointHistory[user][userEpoch] = userNew;
        }
    }

    function _supplyAt(Point memory point, uint256 timestamp) private view returns (uint256) {
        uint256 weekTime = EscrowMath.roundDownToWeek(point.ts);
        for (uint256 i; i < MAX_WEEKS_PER_CHECKPOINT; ++i) {
            weekTime += WEEK;
            int128 slopeDelta = 0;
            if (weekTime > timestamp) {
                weekTime = timestamp;
            } else {
                slopeDelta = slopeChanges[weekTime];
            }
            point.bias -= point.slope * (weekTime - point.ts).toInt256().toInt128();
            if (weekTime == timestamp) break;
            point.slope += slopeDelta;
            point.ts = weekTime.toUint64();
        }
        return point.bias > 0 ? int256(point.bias).toUint256() : 0;
    }

    /// @dev Last global epoch whose point is at or before `timestamp`.
    function _findEpoch(uint256 timestamp) private view returns (uint256) {
        uint256 low = 0;
        uint256 high = epoch;
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (pointHistory[mid].ts <= timestamp) low = mid;
            else high = mid - 1;
        }
        return low;
    }

    /// @dev Last user epoch whose point is at or before `timestamp`; 0 if there is none.
    function _findUserEpoch(address user, uint256 timestamp) private view returns (uint256) {
        uint256 low = 0;
        uint256 high = userPointEpoch[user];
        while (low < high) {
            uint256 mid = (low + high + 1) / 2;
            if (userPointHistory[user][mid].ts <= timestamp) low = mid;
            else high = mid - 1;
        }
        return low;
    }

    function _requirePast(uint256 timepoint) private view {
        uint48 currentClock = clock();
        if (timepoint >= currentClock) revert ERC5805FutureLookup(timepoint, currentClock);
    }
}
