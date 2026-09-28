// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {VotingEscrow} from "../escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../forecast/ForecastRegistry.sol";
import {IEthDepositor} from "../interfaces/IEthDepositor.sol";
import {ISeasonTreasury} from "../interfaces/ISeasonTreasury.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {EmissionSchedule} from "./EmissionSchedule.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title SeasonRewards
/// @notice Pays forecasters with statistically significant skill at the end of each 30-day season, in ETH from
/// revenue and in TENAX from emissions and the treasury top-up, always locked (whitepaper sections 5.6 and 7.2).
/// @dev A season goes through three steps, all permissionless and without loops over participants:
///
/// 1. Registration. Once every round of the season is resolved and its reveal window has closed, anyone can
///    register an eligible participant for a fixed period. Registration settles the participant's pending scores in
///    the registry, so the contribution it records is final.
/// 2. Closing. After the registration period, the season's budget is fixed: TENAX emissions accrued since the
///    previous closing plus the ETH received while the season ran, plus whatever earlier seasons carried over, plus
///    the treasury's top-up for the season. With no registered participant, emissions and ETH carry over to the
///    next season and the treasury burns the top-up instead.
/// 3. Claim. Each registered participant claims `budget * contribution / total registered`. ETH is paid liquid
///    (as WETH or native ETH); TENAX is always delivered into a lock of at least 52 weeks through the vote escrow.
///
/// The denominator is the exact sum of registered contributions, so the payouts of a season never exceed its
/// budget and leave only rounding dust.
contract SeasonRewards is IEthDepositor, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;
    using SafeERC20 for IWETH;
    using SafeCast for uint256;

    struct Season {
        bool closed;
        uint32 participants;
        uint128 totalContribution;
        uint256 tenaxBudget;
        uint256 ethBudget;
    }

    struct Registration {
        uint128 contribution;
        bool claimed;
    }

    /// @notice Minimum lock for TENAX rewards; they can never exit early.
    uint256 public constant REWARD_LOCK = 52 weeks;

    /// @notice Period during which eligible participants can be registered for a season.
    uint256 public constant REGISTRATION_PERIOD = 7 days;

    IERC20 public immutable token;
    IWETH public immutable weth;
    VotingEscrow public immutable escrow;
    ForecastRegistry public immutable registry;
    EmissionSchedule public immutable schedule;
    ISeasonTreasury public immutable treasury;

    /// @notice Opening time of the registry's first round and season.
    uint256 public immutable genesis;
    uint256 public immutable seasonLength;
    uint256 public immutable roundInterval;

    /// @notice Time after a season ends until every round in it has closed its reveal window, at the widest
    /// windows governance can set.
    uint256 public immutable settlementDelay;

    /// @notice Next season to close; seasons close strictly in order.
    uint256 public nextSeasonToClose;

    /// @notice Cumulative emission already assigned to closed seasons.
    uint256 public emissionsAssigned;

    /// @notice Budget left by closed seasons without registered participants, added to the next season to close.
    uint256 public tenaxCarry;
    uint256 public ethCarry;

    /// @notice Cumulative TENAX received from the treasury as season top-ups.
    uint256 public topUpsReceived;

    /// @notice ETH (as WETH) received while each season was running.
    mapping(uint256 season => uint256 amount) public ethReceived;

    mapping(uint256 season => Season) private _seasons;
    mapping(uint256 season => mapping(address participant => Registration)) private _registrations;

    event EthDeposited(address indexed from, uint256 indexed season, uint256 amount);
    event Registered(address indexed participant, uint256 indexed season, uint256 contribution);
    event SeasonClosed(
        uint256 indexed season, uint256 tenaxBudget, uint256 ethBudget, uint256 topUp, uint256 totalContribution
    );
    event Claimed(address indexed participant, uint256 indexed season, uint256 tenax, uint256 eth, bool asEth);

    error ZeroAddress();
    error ZeroAmount();
    error TokenMismatch();
    error RegistrationNotOpen(uint256 opensAt);
    error RegistrationClosed();
    error RoundsPending(uint256 asset);
    error AlreadyRegistered();
    error NotEligible();
    error NotNextSeason(uint256 expected);
    error SeasonNotClosable(uint256 closesAt);
    error SeasonNotClosed();
    error NotRegistered();
    error AlreadyClaimed();
    error UnexpectedEth();

    constructor(
        IERC20 token_,
        IWETH weth_,
        VotingEscrow escrow_,
        ForecastRegistry registry_,
        EmissionSchedule schedule_,
        ISeasonTreasury treasury_
    ) {
        if (
            address(token_) == address(0) || address(weth_) == address(0) || address(escrow_) == address(0)
                || address(registry_) == address(0) || address(schedule_) == address(0)
                || address(treasury_) == address(0)
        ) revert ZeroAddress();
        if (address(escrow_.token()) != address(token_)) revert TokenMismatch();
        token = token_;
        weth = weth_;
        escrow = escrow_;
        registry = registry_;
        schedule = schedule_;
        treasury = treasury_;
        genesis = registry_.genesis();
        seasonLength = registry_.SEASON_LENGTH();
        roundInterval = registry_.ROUND_INTERVAL();
        settlementDelay = registry_.MAX_SUBMISSION_WINDOW() + registry_.HORIZON() + registry_.MAX_REVEAL_WINDOW();
    }

    /// @notice Only WETH unwrapping sends native ETH here.
    receive() external payable {
        if (msg.sender != address(weth)) revert UnexpectedEth();
    }

    // --- revenue ---------------------------------------------------------------

    /// @notice Adds `amount` WETH to the rewards of the season currently running.
    function depositEth(uint256 amount) external nonReentrant {
        if (amount == 0) revert ZeroAmount();
        uint256 season = currentSeason();
        ethReceived[season] += amount;
        emit EthDeposited(msg.sender, season, amount);
        weth.safeTransferFrom(msg.sender, address(this), amount);
    }

    // --- seasons -----------------------------------------------------------------

    /// @notice Registers `participant` for `season`'s rewards with their final contribution. Anyone can call it.
    /// @dev Settles the participant in the registry first. Every round of the season is resolved or voided and past
    /// its reveal window, so nothing scored afterwards can change the season's contribution.
    function register(address participant, uint256 season) external {
        uint256 opensAt = registrationStart(season);
        if (block.timestamp < opensAt) revert RegistrationNotOpen(opensAt);
        if (block.timestamp >= opensAt + REGISTRATION_PERIOD) revert RegistrationClosed();
        uint256 lastRound = lastRoundOf(season);
        uint256 assets = registry.assetCount();
        for (uint256 asset; asset < assets; ++asset) {
            // Every asset must be done with the season; any pending round blocks the whole registration. The
            // loop is bounded by the registry's fixed asset count.
            // forge-lint: disable-next-line(require-revert-in-loop,calls-loop)
            if (registry.assetState(asset).nextRoundToResolve <= lastRound) revert RoundsPending(asset);
        }
        Registration storage registration = _registrations[season][participant];
        if (registration.contribution != 0) revert AlreadyRegistered();

        registry.settle(participant);
        uint256 contribution = registry.seasonStats(participant, season).contribution;
        if (contribution == 0) revert NotEligible();

        registration.contribution = contribution.toUint128();
        Season storage s = _seasons[season];
        s.totalContribution = (s.totalContribution + contribution).toUint128();
        ++s.participants;
        // The only external calls go to the immutable registry, which calls nothing back.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Registered(participant, season, contribution);
    }

    /// @notice Fixes the budget of the next season after its registration period. Anyone can call it.
    function closeSeason(uint256 season) external {
        if (season != nextSeasonToClose) revert NotNextSeason(nextSeasonToClose);
        uint256 closesAt = registrationStart(season) + REGISTRATION_PERIOD;
        if (block.timestamp < closesAt) revert SeasonNotClosable(closesAt);
        nextSeasonToClose = season + 1;

        uint256 emittedNow = schedule.emitted();
        uint256 tenaxBudget = emittedNow - emissionsAssigned + tenaxCarry;
        uint256 ethBudget = ethReceived[season] + ethCarry;
        emissionsAssigned = emittedNow;

        Season storage s = _seasons[season];
        s.closed = true;
        bool hasParticipants = s.totalContribution != 0;
        if (hasParticipants) {
            tenaxCarry = 0;
            ethCarry = 0;
            s.tenaxBudget = tenaxBudget;
            s.ethBudget = ethBudget;
        } else {
            tenaxCarry = tenaxBudget;
            ethCarry = ethBudget;
        }

        // The treasury sends the top-up here before returning, or burns the whole allowance without participants.
        uint256 topUp = treasury.settleSeason(season, ethReceived[season], hasParticipants);
        if (topUp != 0) {
            s.tenaxBudget += topUp;
            topUpsReceived += topUp;
        }
        // The treasury is an immutable protocol contract that only calls the token back.
        // forge-lint: disable-next-line(reentrancy-events)
        emit SeasonClosed(season, s.tenaxBudget, s.ethBudget, topUp, s.totalContribution);
    }

    /// @notice Claims `season`'s reward: TENAX into a 52-week lock and ETH as WETH.
    /// @dev An expired lock that was not withdrawn blocks the delivery; withdraw it first.
    function claim(uint256 season) external nonReentrant {
        _claim(season, false);
    }

    /// @notice Same as `claim`, paying the ETH portion as native ETH to the caller.
    function claimAsEth(uint256 season) external nonReentrant {
        _claim(season, true);
    }

    // --- views -------------------------------------------------------------------

    /// @notice Season running at the current time; revenue received before genesis counts for season 0.
    function currentSeason() public view returns (uint256) {
        if (block.timestamp < genesis) return 0;
        return (block.timestamp - genesis) / seasonLength;
    }

    /// @notice Time at which registration for `season` opens.
    function registrationStart(uint256 season) public view returns (uint256) {
        return genesis + (season + 1) * seasonLength + settlementDelay;
    }

    /// @notice Last round index that belongs to `season`.
    function lastRoundOf(uint256 season) public view returns (uint256) {
        return ((season + 1) * seasonLength - 1) / roundInterval;
    }

    function seasonInfo(uint256 season) external view returns (Season memory) {
        return _seasons[season];
    }

    function registrationOf(uint256 season, address participant) external view returns (Registration memory) {
        return _registrations[season][participant];
    }

    /// @notice Reward still claimable by `participant` for `season`; zero before the season closes.
    function claimable(uint256 season, address participant) public view returns (uint256 tenax, uint256 eth) {
        Season storage s = _seasons[season];
        Registration storage registration = _registrations[season][participant];
        if (!s.closed || registration.claimed || registration.contribution == 0) return (0, 0);
        tenax = s.tenaxBudget * registration.contribution / s.totalContribution;
        eth = s.ethBudget * registration.contribution / s.totalContribution;
    }

    // --- internals ---------------------------------------------------------------

    function _claim(uint256 season, bool asEth) private {
        if (!_seasons[season].closed) revert SeasonNotClosed();
        Registration storage registration = _registrations[season][msg.sender];
        if (registration.contribution == 0) revert NotRegistered();
        if (registration.claimed) revert AlreadyClaimed();

        (uint256 tenax, uint256 eth) = claimable(season, msg.sender);
        registration.claimed = true;
        emit Claimed(msg.sender, season, tenax, eth, asEth);

        if (tenax != 0) {
            token.forceApprove(address(escrow), tenax);
            escrow.createLockFor(msg.sender, tenax, REWARD_LOCK);
        }
        if (eth != 0) {
            if (asEth) {
                weth.withdraw(eth);
                Address.sendValue(payable(msg.sender), eth);
            } else {
                weth.safeTransfer(msg.sender, eth);
            }
        }
    }
}
