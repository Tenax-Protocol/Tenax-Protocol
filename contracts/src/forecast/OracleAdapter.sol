// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {SafeCast} from "@openzeppelin/contracts/utils/math/SafeCast.sol";

/// @notice Chainlink aggregator interface (AggregatorV3Interface).
interface IAggregatorV3 {
    function decimals() external view returns (uint8);

    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);

    function getRoundData(uint80 roundId)
        external
        view
        returns (uint80 roundId_, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @title OracleAdapter
/// @notice Reads validated Chainlink prices at an exact past timestamp.
/// @dev Instead of reading the latest price when a keeper happens to call, the caller names the Chainlink round
/// that was active at the timestamp and the adapter verifies it: that round was published at or before the
/// timestamp and the next round (if any) was published after it. The result is deterministic, so a late keeper
/// cannot change it. The L2 sequencer status at the timestamp is verified the same way.
///
/// A price is valid when the answer is positive, it is not older than the feed's staleness tolerance at the
/// timestamp, and the sequencer had been up for at least the grace period. Feeds are fixed at deployment.
contract OracleAdapter {
    /// @dev Which timestamp of a round tells when it became active.
    enum RoundTime {
        UpdatedAt, // price feeds
        StartedAt // sequencer uptime feed: when the status changed
    }

    struct Feed {
        IAggregatorV3 aggregator;
        uint64 stalenessTolerance;
        uint8 decimals;
    }

    uint256 internal constant WAD_DECIMALS = 18;

    /// @notice L2 sequencer uptime feed (answer 0 = up); zero address disables the check (for testnets).
    IAggregatorV3 public immutable sequencerUptimeFeed;

    /// @notice Minimum time the sequencer must have been up before a price counts.
    uint256 public immutable sequencerGracePeriod;

    Feed[] private _feeds;

    error LengthMismatch();
    error ZeroAddress();
    error UnsupportedDecimals(uint8 decimals);
    error UnknownAsset(uint256 asset);
    error FutureTimestamp(uint256 timestamp);
    error WrongRoundHint(address aggregator, uint80 roundId);

    constructor(
        IAggregatorV3[] memory aggregators,
        uint64[] memory stalenessTolerances,
        IAggregatorV3 sequencerUptimeFeed_,
        uint256 sequencerGracePeriod_
    ) {
        if (aggregators.length != stalenessTolerances.length) {
            revert LengthMismatch();
        }
        for (uint256 i; i < aggregators.length; ++i) {
            // Deployment-time validation: any invalid feed aborts the deployment.
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (address(aggregators[i]) == address(0)) revert ZeroAddress();
            // forge-lint: disable-next-line(calls-loop)
            uint8 feedDecimals = aggregators[i].decimals();
            // forge-lint: disable-next-line(require-revert-in-loop)
            if (feedDecimals > WAD_DECIMALS) revert UnsupportedDecimals(feedDecimals);
            _feeds.push(Feed(aggregators[i], stalenessTolerances[i], feedDecimals));
        }
        sequencerUptimeFeed = sequencerUptimeFeed_;
        sequencerGracePeriod = sequencerGracePeriod_;
    }

    /// @notice Number of supported assets; assets are indexed from zero in deployment order.
    function assetCount() external view returns (uint256) {
        return _feeds.length;
    }

    /// @notice Feed configuration of `asset`.
    function feed(uint256 asset) external view returns (Feed memory) {
        if (asset >= _feeds.length) revert UnknownAsset(asset);
        return _feeds[asset];
    }

    /// @notice Price of `asset` at `timestamp`, normalized to 18 decimals.
    /// @param priceRound Chainlink round of the asset feed that was active at `timestamp`.
    /// @param sequencerRound Round of the sequencer uptime feed that was active at `timestamp` (ignored when the
    /// check is disabled).
    /// @return valid False when the price was stale, non-positive or the sequencer was down or in its grace period.
    /// @return price The price in 18 decimals, or zero when not valid.
    /// @dev Reverts if either round hint is not the round active at `timestamp`.
    function priceAt(uint256 asset, uint256 timestamp, uint80 priceRound, uint80 sequencerRound)
        external
        view
        returns (bool valid, uint256 price)
    {
        if (asset >= _feeds.length) revert UnknownAsset(asset);
        if (timestamp > block.timestamp) revert FutureTimestamp(timestamp);

        bool sequencerUp = true;
        if (address(sequencerUptimeFeed) != address(0)) {
            (int256 status, uint256 since) =
                _roundAt(sequencerUptimeFeed, timestamp, sequencerRound, RoundTime.StartedAt);
            sequencerUp = status == 0 && timestamp - since >= sequencerGracePeriod;
        }

        Feed memory f = _feeds[asset];
        (int256 answer, uint256 updatedAt) = _roundAt(f.aggregator, timestamp, priceRound, RoundTime.UpdatedAt);
        valid = sequencerUp && answer > 0 && timestamp - updatedAt <= f.stalenessTolerance;
        if (valid) price = SafeCast.toUint256(answer) * 10 ** (WAD_DECIMALS - f.decimals);
    }

    /// @dev Verifies that `hint` is the round active at `timestamp` and returns its answer and time.
    /// Price feeds are timed by `updatedAt`; the sequencer feed by `startedAt`, when its status changed.
    function _roundAt(IAggregatorV3 aggregator, uint256 timestamp, uint80 hint, RoundTime field)
        private
        view
        returns (int256 answer, uint256 time)
    {
        (bool exists, int256 hintAnswer, uint256 hintTime) = _tryRound(aggregator, hint, field);
        if (!exists || hintTime > timestamp) revert WrongRoundHint(address(aggregator), hint);

        (bool nextExists,, uint256 nextTime) = _tryRound(aggregator, hint + 1, field);
        if (nextExists) {
            if (nextTime <= timestamp) revert WrongRoundHint(address(aggregator), hint);
        } else {
            // Without a next round in this phase, the hint must be the latest round.
            // Only the round id matters here.
            // forge-lint: disable-next-line(unused-return)
            (uint80 latest,,,,) = aggregator.latestRoundData();
            if (latest != hint) revert WrongRoundHint(address(aggregator), hint);
        }
        return (hintAnswer, hintTime);
    }

    /// @dev Chainlink proxies either revert or return zeros for rounds that do not exist.
    function _tryRound(IAggregatorV3 aggregator, uint80 roundId, RoundTime field)
        private
        view
        returns (bool exists, int256 answer, uint256 time)
    {
        try aggregator.getRoundData(roundId) returns (
            uint80, int256 answer_, uint256 startedAt, uint256 updatedAt, uint80
        ) {
            time = field == RoundTime.StartedAt ? startedAt : updatedAt;
            exists = time != 0;
            answer = answer_;
        } catch {
            // A missing round leaves the defaults: it does not exist.
        }
    }
}
