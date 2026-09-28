// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VotingEscrow} from "../escrow/VotingEscrow.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";

/// @title FeeDistributor
/// @notice Pays veTENAX holders their weekly share of ETH revenue (whitepaper section 5.5).
/// @dev Follows the design of Curve's fee distributor. WETH received during week `w` is attributed to that week and
/// shared pro rata by veTENAX balance at the start of the week, `t_w`. Weeks are finalized in order once they end,
/// caching the total veTENAX at `t_w`; a week with no veTENAX at its start rolls its WETH over to the next week.
/// Holders pull their shares, iterating over at most 52 weeks per call. Payouts are WETH, or native ETH sent to the
/// caller after every state update.
contract FeeDistributor is ReentrancyGuardTransient {
    using SafeERC20 for IWETH;

    uint256 public constant WEEK = 1 weeks;

    /// @notice Upper bound on weeks processed by a single finalization or claim.
    uint256 public constant MAX_WEEKS_PER_CALL = 52;

    IWETH public immutable weth;
    VotingEscrow public immutable escrow;

    /// @notice First week that receives revenue: the week of deployment.
    uint256 public immutable startWeek;

    /// @notice Next week to finalize; every earlier week is final.
    uint256 public weekCursor;

    mapping(uint256 week => uint256 amount) public tokensPerWeek;
    mapping(uint256 week => uint256 supply) public veSupply;

    /// @notice Next week each holder has not claimed yet; zero before their first claim.
    mapping(address holder => uint256 week) public holderWeekCursor;

    event EthDeposited(address indexed from, uint256 indexed week, uint256 amount);
    event WeekFinalized(uint256 indexed week, uint256 veSupply, uint256 amount);
    event RolledOver(uint256 indexed fromWeek, uint256 amount);
    event Claimed(address indexed holder, uint256 amount, uint256 nextWeek, bool asEth);

    error ZeroAddress();
    error ZeroAmount();
    error UnexpectedEth();

    constructor(IWETH weth_, VotingEscrow escrow_) {
        if (address(weth_) == address(0) || address(escrow_) == address(0)) revert ZeroAddress();
        weth = weth_;
        escrow = escrow_;
        uint256 week = _weekOf(block.timestamp);
        startWeek = week;
        weekCursor = week;
    }

    /// @notice Only WETH unwrapping sends native ETH here.
    receive() external payable {
        if (msg.sender != address(weth)) revert UnexpectedEth();
    }

    /// @notice Adds `amount` WETH to the current week's distribution.
    function depositEth(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        _finalizeWeeks();
        uint256 week = _weekOf(block.timestamp);
        tokensPerWeek[week] += amount;
        emit EthDeposited(msg.sender, week, amount);
        weth.safeTransferFrom(msg.sender, address(this), amount);
    }

    /// @notice Finalizes up to 52 ended weeks. Claims and deposits do it too; anyone can call it.
    function checkpoint() external {
        _finalizeWeeks();
    }

    /// @notice Pays `holder` their shares of up to 52 final weeks, as WETH. Anyone can trigger it for anyone.
    function claim(address holder) external nonReentrant returns (uint256 amount) {
        amount = _claim(holder, false);
        if (amount != 0) weth.safeTransfer(holder, amount);
    }

    /// @notice Pays the caller their shares of up to 52 final weeks, as native ETH.
    function claimAsEth() external nonReentrant returns (uint256 amount) {
        amount = _claim(msg.sender, true);
        if (amount != 0) {
            weth.withdraw(amount);
            Address.sendValue(payable(msg.sender), amount);
        }
    }

    /// @notice Shares of `holder` in weeks already finalized and not yet claimed, up to 52 weeks.
    function claimable(address holder) external view returns (uint256 amount) {
        (amount,) = _pending(holder);
    }

    // --- internals ---------------------------------------------------------------

    function _claim(address holder, bool asEth) private returns (uint256 amount) {
        _finalizeWeeks();
        uint256 next;
        (amount, next) = _pending(holder);
        if (next != 0) holderWeekCursor[holder] = next;
        emit Claimed(holder, amount, next, asEth);
    }

    /// @dev Sums the holder's shares from their cursor over at most 52 final weeks. A holder's first week is the
    /// first week that starts after their first lock, since their balance at any earlier week start is zero.
    function _pending(address holder) private view returns (uint256 amount, uint256 week) {
        week = holderWeekCursor[holder];
        if (week == 0) {
            if (escrow.userPointEpoch(holder) == 0) return (0, 0);
            // Only the timestamp of the holder's first checkpoint matters here.
            // forge-lint: disable-next-line(unused-return)
            (,, uint64 firstLock) = escrow.userPointHistory(holder, 1);
            week = _weekOf(uint256(firstLock) + WEEK - 1);
            if (week < startWeek) week = startWeek;
        }
        uint256 end = weekCursor;
        for (uint256 i = 0; i < MAX_WEEKS_PER_CALL && week < end; ++i) {
            uint256 supply = veSupply[week];
            if (supply != 0) {
                // Bounded by MAX_WEEKS_PER_CALL; each step is a historical balance read.
                // forge-lint: disable-next-line(calls-loop)
                uint256 balance = escrow.balanceOfAt(holder, week);
                if (balance != 0) amount += tokensPerWeek[week] * balance / supply;
            }
            week += WEEK;
        }
    }

    function _finalizeWeeks() private {
        uint256 week = weekCursor;
        for (uint256 i = 0; i < MAX_WEEKS_PER_CALL && week + WEEK <= block.timestamp; ++i) {
            // Bounded by MAX_WEEKS_PER_CALL; each step is a historical supply read.
            // forge-lint: disable-next-line(calls-loop)
            uint256 supply = escrow.totalSupplyAt(week);
            veSupply[week] = supply;
            uint256 amount = tokensPerWeek[week];
            if (supply == 0 && amount != 0) {
                tokensPerWeek[week] = 0;
                tokensPerWeek[week + WEEK] += amount;
                emit RolledOver(week, amount);
                amount = 0;
            }
            emit WeekFinalized(week, supply, amount);
            week += WEEK;
        }
        weekCursor = week;
    }

    function _weekOf(uint256 timestamp) private pure returns (uint256) {
        // Truncating division is the rounding itself.
        // forge-lint: disable-next-line(divide-before-multiply)
        return timestamp / WEEK * WEEK;
    }
}
