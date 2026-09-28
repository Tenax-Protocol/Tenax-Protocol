// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BrierMath} from "./BrierMath.sol";
import {OracleAdapter} from "./OracleAdapter.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @title ForecastRegistry
/// @notice On-chain forecasting rounds: commit-reveal, oracle resolution, Brier scoring against a moving base rate,
/// reputation-weighted aggregation and season statistics for rewards (whitepaper section 3).
/// @dev Each asset has one round per day. Round `k` opens at `genesis + k days`, accepts commitments until
/// `commitEnd`, resolves 24 hours later and accepts reveals until `revealEnd`. The threshold X and base rate b are
/// copied into the round when it opens. Rounds are resolved in order, which updates X and b.
///
/// Scoring is lazy: each participant keeps a short list of pending commitments that is settled on their next
/// interaction (or by anyone through `settle`). A revealed commitment is scored once its round is resolved; an
/// unrevealed one scores the worst possible forecast after the reveal window; a voided round is dropped. The list
/// is bounded, so no function ever loops over participants.
///
/// The contract holds no funds.
contract ForecastRegistry {
    using SafeCast for uint256;
    using SafeCast for int256;

    enum RoundStatus {
        None,
        Open,
        Resolved,
        Voided
    }

    struct Round {
        RoundStatus status;
        bool outcome;
        bool finalized;
        uint16 baseRateBps;
        uint16 aggregateBps;
        uint32 commitments;
        uint32 reveals;
        uint64 commitEnd;
        uint64 resolveTime;
        uint64 revealEnd;
        uint256 threshold;
        uint256 refPrice;
        uint256 closePrice;
        uint256 weightSum;
        uint256 weightedForecastSum;
    }

    struct Commitment {
        bytes32 hash;
        uint64 weight;
        uint16 forecast;
        bool revealed;
    }

    struct AssetState {
        uint256 threshold;
        uint256 baseRate;
        uint256 nextRoundToResolve;
    }

    struct SeasonStats {
        uint32 rounds;
        int128 skillSum;
        uint128 skillSquares;
        uint128 contribution;
    }

    /// @notice Hints naming the Chainlink rounds active at a round's reference and closing times.
    struct PriceHints {
        uint80 refPriceRound;
        uint80 refSequencerRound;
        uint80 closePriceRound;
        uint80 closeSequencerRound;
    }

    uint256 public constant ROUND_INTERVAL = 1 days;
    uint256 public constant HORIZON = 24 hours;
    uint256 public constant SEASON_LENGTH = 30 days;
    uint256 public constant ELIGIBILITY_WINDOW = 3;
    uint256 public constant MIN_SUBMISSION_WINDOW = 5 minutes;
    uint256 public constant MAX_SUBMISSION_WINDOW = 6 hours;
    uint256 public constant MIN_REVEAL_WINDOW = 12 hours;
    uint256 public constant MAX_REVEAL_WINDOW = 7 days;

    /// @notice veTENAX required to submit a forecast.
    uint256 public constant MIN_VE = 5000e18;

    /// @notice Upper bound on unsettled commitments per participant; far above what the windows allow.
    uint256 public constant MAX_PENDING = 32;

    IVotes public immutable escrow;
    OracleAdapter public immutable oracle;
    address public immutable governance;
    uint256 public immutable genesis;
    uint256 public immutable assetCount;

    uint256 public submissionWindow;
    uint256 public revealWindow;

    mapping(uint256 asset => AssetState) private _assets;
    mapping(uint256 asset => mapping(uint256 round => Round)) private _rounds;
    mapping(uint256 asset => mapping(uint256 round => mapping(address participant => Commitment))) private _commitments;

    /// @notice Reputation of each participant: exponential moving average of skill, in 1e8 units.
    mapping(address participant => int256 ema) public reputation;

    mapping(address participant => uint256[] packedRounds) private _pending;
    mapping(address participant => mapping(uint256 season => SeasonStats)) private _seasonStats;

    /// @notice Sum over eligible participants of their positive season skill; the reward denominator.
    mapping(uint256 season => uint256 total) public totalContribution;

    event RoundOpened(
        uint256 indexed asset,
        uint256 indexed round,
        uint256 threshold,
        uint256 baseRateBps,
        uint256 commitEnd,
        uint256 resolveTime,
        uint256 revealEnd
    );
    event Committed(uint256 indexed asset, uint256 indexed round, address indexed participant, uint256 weight);
    event Revealed(uint256 indexed asset, uint256 indexed round, address indexed participant, uint256 forecast);
    event RoundResolved(
        uint256 indexed asset, uint256 indexed round, uint256 refPrice, uint256 closePrice, bool outcome
    );
    event RoundVoided(uint256 indexed asset, uint256 indexed round);
    event RoundFinalized(
        uint256 indexed asset, uint256 indexed round, uint256 aggregateBps, uint256 aggregateBrier, uint256 reveals
    );
    event Scored(
        address indexed participant,
        uint256 indexed asset,
        uint256 indexed round,
        uint256 season,
        int256 skill,
        bool revealed,
        int256 reputation
    );
    event ContributionUpdated(address indexed participant, uint256 indexed season, uint256 contribution);
    event SubmissionWindowUpdated(uint256 window);
    event RevealWindowUpdated(uint256 window);

    error ZeroAddress();
    error LengthMismatch();
    error NotGovernance();
    error UnknownAsset(uint256 asset);
    error OutOfBounds(uint256 value);
    error NotStarted();
    error NotCurrentRound(uint256 round);
    error SubmissionClosed();
    error InsufficientVotingPower(uint256 votes);
    error AlreadyCommitted();
    error TooManyPending();
    error NotCommitted();
    error AlreadyRevealed();
    error RevealNotOpen();
    error RevealClosed();
    error InvalidForecast(uint256 forecast);
    error CommitmentMismatch();
    error NotNextRound(uint256 expected);
    error NotResolvable();
    error NotExpired();
    error NotFinalizable();

    /// @param escrow_ Vote escrow whose balance gates participation.
    /// @param oracle_ Oracle adapter; its asset indexes are this registry's asset indexes.
    /// @param governance_ Timelock allowed to adjust the submission and reveal windows within bounds.
    /// @param genesis_ Opening time of round 0 for every asset.
    /// @param initialThresholds Initial X per asset (1e18 fraction), from the last year of prices.
    /// @param initialBaseRates Initial b per asset (1e18 fraction), from the last year of prices.
    constructor(
        IVotes escrow_,
        OracleAdapter oracle_,
        address governance_,
        uint256 genesis_,
        uint256 submissionWindow_,
        uint256 revealWindow_,
        uint256[] memory initialThresholds,
        uint256[] memory initialBaseRates
    ) {
        if (address(escrow_) == address(0) || address(oracle_) == address(0) || governance_ == address(0)) {
            revert ZeroAddress();
        }
        uint256 count = oracle_.assetCount();
        if (initialThresholds.length != count || initialBaseRates.length != count) revert LengthMismatch();

        escrow = escrow_;
        oracle = oracle_;
        governance = governance_;
        genesis = genesis_;
        assetCount = count;
        _setSubmissionWindow(submissionWindow_);
        _setRevealWindow(revealWindow_);

        for (uint256 asset; asset < count; ++asset) {
            // Deployment-time validation: any invalid initial value aborts the deployment.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (initialThresholds[asset] == 0) revert OutOfBounds(initialThresholds[asset]);
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (initialBaseRates[asset] > BrierMath.WAD) revert OutOfBounds(initialBaseRates[asset]);
            _assets[asset] = AssetState(initialThresholds[asset], initialBaseRates[asset], 0);
        }
    }

    // --- governance ------------------------------------------------------------

    /// @notice Sets the submission window for rounds opened from now on.
    function setSubmissionWindow(uint256 window) external {
        if (msg.sender != governance) revert NotGovernance();
        _setSubmissionWindow(window);
    }

    /// @notice Sets the reveal window for rounds opened from now on.
    function setRevealWindow(uint256 window) external {
        if (msg.sender != governance) revert NotGovernance();
        _setRevealWindow(window);
    }

    // --- participants ----------------------------------------------------------

    /// @notice Commitment hash expected by `commit`, to be computed off-chain with a secret salt.
    function commitmentHash(uint256 asset, uint256 round, address participant, uint256 forecast, bytes32 salt)
        public
        view
        returns (bytes32)
    {
        return keccak256(abi.encode(block.chainid, address(this), asset, round, participant, forecast, salt));
    }

    /// @notice Commits a hidden forecast for the current round of `asset`.
    function commit(uint256 asset, uint256 round, bytes32 hash) external {
        _requireAsset(asset);
        if (round != currentRound()) revert NotCurrentRound(round);
        uint256 votes = escrow.getVotes(msg.sender);
        if (votes < MIN_VE) revert InsufficientVotingPower(votes);

        Round storage r = _openRound(asset, round);
        if (block.timestamp >= r.commitEnd) revert SubmissionClosed();

        _settle(msg.sender);
        Commitment storage c = _commitments[asset][round][msg.sender];
        if (c.hash != bytes32(0)) revert AlreadyCommitted();
        if (_pending[msg.sender].length >= MAX_PENDING) revert TooManyPending();

        uint256 w = BrierMath.weight(reputation[msg.sender]);
        c.hash = hash;
        c.weight = w.toUint64();
        ++r.commitments;
        _pending[msg.sender].push(_pack(asset, round));
        emit Committed(asset, round, msg.sender, w);
    }

    /// @notice Reveals a committed forecast (bps) after the horizon ends, adding it to the aggregate.
    function reveal(uint256 asset, uint256 round, uint256 forecast, bytes32 salt) external {
        Round storage r = _rounds[asset][round];
        if (r.status == RoundStatus.None || block.timestamp < r.resolveTime) revert RevealNotOpen();
        if (block.timestamp >= r.revealEnd) revert RevealClosed();
        if (forecast > BrierMath.BPS) revert InvalidForecast(forecast);

        Commitment storage c = _commitments[asset][round][msg.sender];
        if (c.hash == bytes32(0)) revert NotCommitted();
        if (c.revealed) revert AlreadyRevealed();
        if (commitmentHash(asset, round, msg.sender, forecast, salt) != c.hash) revert CommitmentMismatch();

        c.revealed = true;
        c.forecast = forecast.toUint16();
        r.weightSum += c.weight;
        r.weightedForecastSum += uint256(c.weight) * forecast;
        ++r.reveals;
        emit Revealed(asset, round, msg.sender, forecast);

        _settle(msg.sender);
    }

    /// @notice Scores whatever is ready among `participant`'s pending commitments. Anyone can call it.
    function settle(address participant) external {
        _settle(participant);
    }

    // --- keepers ---------------------------------------------------------------

    /// @notice Resolves the next round of `asset` with oracle prices at its reference and closing times.
    /// @dev Voids the round if either price is invalid (stale, non-positive or sequencer down).
    function resolveRound(uint256 asset, uint256 round, PriceHints calldata hints) external {
        Round storage r = _nextRound(asset, round);
        if (block.timestamp < r.resolveTime) revert NotResolvable();

        (bool refValid, uint256 refPrice) =
            oracle.priceAt(asset, r.commitEnd, hints.refPriceRound, hints.refSequencerRound);
        (bool closeValid, uint256 closePrice) =
            oracle.priceAt(asset, r.resolveTime, hints.closePriceRound, hints.closeSequencerRound);

        AssetState storage state = _assets[asset];
        state.nextRoundToResolve = round + 1;
        if (!refValid || !closeValid) {
            r.status = RoundStatus.Voided;
            emit RoundVoided(asset, round);
            return;
        }

        uint256 absReturn = BrierMath.absoluteReturn(refPrice, closePrice);
        bool outcome = absReturn > r.threshold;
        r.status = RoundStatus.Resolved;
        r.outcome = outcome;
        r.refPrice = refPrice;
        r.closePrice = closePrice;
        state.threshold = BrierMath.updateThreshold(state.threshold, absReturn);
        state.baseRate = BrierMath.updateBaseRate(state.baseRate, outcome);
        emit RoundResolved(asset, round, refPrice, closePrice, outcome);
    }

    /// @notice Voids the next round of `asset` if nobody resolved it before its reveal window closed.
    function voidExpiredRound(uint256 asset, uint256 round) external {
        Round storage r = _nextRound(asset, round);
        if (block.timestamp < r.revealEnd) revert NotExpired();
        _assets[asset].nextRoundToResolve = round + 1;
        r.status = RoundStatus.Voided;
        emit RoundVoided(asset, round);
    }

    /// @notice Publishes the aggregate forecast of a round after its reveal window.
    function finalizeRound(uint256 asset, uint256 round) external {
        Round storage r = _rounds[asset][round];
        if (r.finalized || (r.status != RoundStatus.Resolved && r.status != RoundStatus.Voided)) {
            revert NotFinalizable();
        }
        if (block.timestamp < r.revealEnd) revert NotFinalizable();

        r.finalized = true;
        uint256 aggregateBrier = 0;
        if (r.status == RoundStatus.Resolved && r.weightSum != 0) {
            uint256 aggregate = r.weightedForecastSum / r.weightSum;
            r.aggregateBps = aggregate.toUint16();
            aggregateBrier = BrierMath.brier(aggregate, r.outcome);
        }
        emit RoundFinalized(asset, round, r.aggregateBps, aggregateBrier, r.reveals);
    }

    // --- views -----------------------------------------------------------------

    /// @notice Index of the round currently accepting commitments (or about to).
    function currentRound() public view returns (uint256) {
        if (block.timestamp < genesis) revert NotStarted();
        return (block.timestamp - genesis) / ROUND_INTERVAL;
    }

    /// @notice Season a round belongs to.
    function seasonOf(uint256 round) public pure returns (uint256) {
        return round * ROUND_INTERVAL / SEASON_LENGTH;
    }

    function assetState(uint256 asset) external view returns (AssetState memory) {
        return _assets[asset];
    }

    function roundInfo(uint256 asset, uint256 round) external view returns (Round memory) {
        return _rounds[asset][round];
    }

    function commitmentOf(uint256 asset, uint256 round, address participant) external view returns (Commitment memory) {
        return _commitments[asset][round][participant];
    }

    function pendingCount(address participant) external view returns (uint256) {
        return _pending[participant].length;
    }

    function seasonStats(address participant, uint256 season) external view returns (SeasonStats memory) {
        return _seasonStats[participant][season];
    }

    /// @notice Whether `participant` is currently eligible for `season`'s rewards.
    function isEligible(address participant, uint256 season) public view returns (bool) {
        (uint256 seasonRounds, uint256 rounds, int256 sum, uint256 squares) = _window(participant, season);
        return BrierMath.isEligible(seasonRounds, rounds, sum, squares);
    }

    // --- internals ---------------------------------------------------------------

    function _setSubmissionWindow(uint256 window) private {
        if (window < MIN_SUBMISSION_WINDOW || window > MAX_SUBMISSION_WINDOW) revert OutOfBounds(window);
        submissionWindow = window;
        emit SubmissionWindowUpdated(window);
    }

    function _setRevealWindow(uint256 window) private {
        if (window < MIN_REVEAL_WINDOW || window > MAX_REVEAL_WINDOW) revert OutOfBounds(window);
        revealWindow = window;
        emit RevealWindowUpdated(window);
    }

    function _requireAsset(uint256 asset) private view {
        if (asset >= assetCount) revert UnknownAsset(asset);
    }

    /// @dev Opens a round on first use, copying X and b and the current windows. Times follow the schedule, so a
    /// round opened late (for example at resolution, when nobody committed) keeps its original deadlines.
    function _openRound(uint256 asset, uint256 round) private returns (Round storage r) {
        r = _rounds[asset][round];
        if (r.status != RoundStatus.None) return r;

        AssetState storage state = _assets[asset];
        uint256 commitEnd = genesis + round * ROUND_INTERVAL + submissionWindow;
        uint256 resolveTime = commitEnd + HORIZON;
        uint256 revealEnd = resolveTime + revealWindow;

        r.status = RoundStatus.Open;
        r.threshold = state.threshold;
        r.baseRateBps = BrierMath.toBps(state.baseRate).toUint16();
        r.commitEnd = commitEnd.toUint64();
        r.resolveTime = resolveTime.toUint64();
        r.revealEnd = revealEnd.toUint64();
        emit RoundOpened(asset, round, r.threshold, r.baseRateBps, commitEnd, resolveTime, revealEnd);
    }

    /// @dev Rounds resolve strictly in order, so X and b evolve in the same order as the rounds.
    function _nextRound(uint256 asset, uint256 round) private returns (Round storage r) {
        _requireAsset(asset);
        uint256 expected = _assets[asset].nextRoundToResolve;
        if (round != expected) revert NotNextRound(expected);
        if (genesis + round * ROUND_INTERVAL > block.timestamp) revert NotResolvable();
        // The round at the pointer is never settled: settling it is what moves the pointer.
        r = _openRound(asset, round);
    }

    function _settle(address participant) private {
        uint256[] storage list = _pending[participant];
        uint256 i = 0;
        while (i < list.length) {
            (uint256 asset, uint256 round) = _unpack(list[i]);
            Round storage r = _rounds[asset][round];

            if (r.status == RoundStatus.Voided) {
                _removePending(list, i);
                continue;
            }
            if (r.status == RoundStatus.Resolved) {
                Commitment storage c = _commitments[asset][round][participant];
                if (c.revealed) {
                    _score(participant, asset, round, BrierMath.skill(c.forecast, r.baseRateBps, r.outcome), true);
                    _removePending(list, i);
                    continue;
                }
                if (block.timestamp >= r.revealEnd) {
                    _score(participant, asset, round, BrierMath.missedRevealSkill(r.baseRateBps, r.outcome), false);
                    _removePending(list, i);
                    continue;
                }
            }
            ++i;
        }
    }

    function _score(address participant, uint256 asset, uint256 round, int256 skillValue, bool revealed) private {
        int256 ema = BrierMath.updateReputation(reputation[participant], skillValue);
        reputation[participant] = ema;

        uint256 season = seasonOf(round);
        SeasonStats storage stats = _seasonStats[participant][season];
        ++stats.rounds;
        stats.skillSum += skillValue.toInt128();
        stats.skillSquares += (skillValue * skillValue).toUint256().toUint128();

        // A season's stats feed the eligibility window of that season and the next two.
        for (uint256 s = season; s < season + ELIGIBILITY_WINDOW; ++s) {
            _updateContribution(participant, s);
        }
        emit Scored(participant, asset, round, season, skillValue, revealed, ema);
    }

    function _updateContribution(address participant, uint256 season) private {
        SeasonStats storage stats = _seasonStats[participant][season];
        uint256 contribution = 0;
        if (isEligible(participant, season) && stats.skillSum > 0) {
            contribution = int256(stats.skillSum).toUint256();
        }
        uint256 previous = stats.contribution;
        if (contribution == previous) return;
        stats.contribution = contribution.toUint128();
        totalContribution[season] = totalContribution[season] - previous + contribution;
        emit ContributionUpdated(participant, season, contribution);
    }

    function _window(address participant, uint256 season)
        private
        view
        returns (uint256 seasonRounds, uint256 rounds, int256 sum, uint256 squares)
    {
        seasonRounds = _seasonStats[participant][season].rounds;
        uint256 first = season + 1 >= ELIGIBILITY_WINDOW ? season + 1 - ELIGIBILITY_WINDOW : 0;
        for (uint256 s = first; s <= season; ++s) {
            SeasonStats storage stats = _seasonStats[participant][s];
            rounds += stats.rounds;
            sum += stats.skillSum;
            squares += stats.skillSquares;
        }
    }

    function _removePending(uint256[] storage list, uint256 index) private {
        list[index] = list[list.length - 1];
        list.pop();
    }

    function _pack(uint256 asset, uint256 round) private pure returns (uint256) {
        return (asset << 128) | round;
    }

    function _unpack(uint256 packed) private pure returns (uint256 asset, uint256 round) {
        return (packed >> 128, packed & type(uint128).max);
    }
}
