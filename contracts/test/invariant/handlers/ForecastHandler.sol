// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForecastRegistry} from "../../../src/forecast/ForecastRegistry.sol";
import {MockAggregator} from "../../mocks/MockAggregator.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives a realistic forecasting population. The handler decides each round's outcome in advance; the first
/// half of the actors receive informative forecasts (skilled), the rest guess. Most reveals happen, some are
/// forgotten, keepers resolve whatever is due with prices published in time order, and expired rounds are voided.
contract ForecastHandler is Test {
    ForecastRegistry public immutable registry;
    MockAggregator[2] internal feeds;
    uint80 internal immutable sequencerRound;
    uint256 internal immutable genesis;
    uint256 internal immutable window;

    address[] public actors;
    mapping(address actor => mapping(uint256 asset => mapping(uint256 round => uint256 forecastPlusOne))) internal
        committed;
    mapping(uint256 asset => mapping(uint256 round => uint256 outcomePlusOne)) internal plannedOutcome;
    mapping(uint256 asset => mapping(uint256 time => uint80 hint)) internal published;
    mapping(uint256 asset => int256 price) internal lastPrice;

    uint256 public ghostCommits;
    uint256 public ghostVoidedCommits;
    bool public ghostWeightOutOfBounds;
    uint256 public maxRoundTouched;
    mapping(string operation => uint256 count) public executed;

    constructor(
        ForecastRegistry registry_,
        MockAggregator btcFeed,
        MockAggregator ethFeed,
        uint80 sequencerRound_,
        address[] memory actors_
    ) {
        registry = registry_;
        feeds = [btcFeed, ethFeed];
        sequencerRound = sequencerRound_;
        genesis = registry_.genesis();
        window = registry_.submissionWindow();
        actors = actors_;
        lastPrice[0] = 100_000e8;
        lastPrice[1] = 3000e8;
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    // --- participants ----------------------------------------------------------------

    /// @dev Moves into a submission window if needed and has every actor commit on both assets.
    function commitRound(uint256 seed) external {
        _revealOpen(seed); // participants reveal what is open when they come back to forecast
        uint256 round = registry.currentRound();
        if (vm.getBlockTimestamp() >= genesis + round * 1 days + window) {
            ++round;
            vm.warp(genesis + round * 1 days + bound(seed, 0, window - 1));
        }
        for (uint256 asset; asset < 2; ++asset) {
            bool outcome = uint256(keccak256(abi.encode(seed, asset, round))) % 100 < 36;
            if (plannedOutcome[asset][round] == 0) plannedOutcome[asset][round] = outcome ? 2 : 1;
            outcome = plannedOutcome[asset][round] == 2;

            for (uint256 i; i < actors.length; ++i) {
                address actor = actors[i];
                if (committed[actor][asset][round] != 0) continue;
                uint256 forecast = i < actors.length / 2
                    ? (outcome ? 8000 : 1500)  // skilled: informative forecasts
                    : uint256(keccak256(abi.encode(seed, actor, asset, round))) % 10_001; // guessing
                _commit(actor, asset, round, forecast);
            }
        }
        if (round > maxRoundTouched) maxRoundTouched = round;
        executed["commitRound"]++;
    }

    /// @dev Reveals open commitments of every actor, except roughly one in eight that is forgotten.
    function revealAll(uint256 seed) external {
        uint256 current = registry.currentRound();
        if (current >= 1) {
            ForecastRegistry.Round memory r = registry.roundInfo(0, current - 1);
            if (r.status != ForecastRegistry.RoundStatus.None && vm.getBlockTimestamp() < r.resolveTime) {
                vm.warp(r.resolveTime);
            }
        }
        _revealOpen(seed);
        executed["revealAll"]++;
    }

    function settleAll() external {
        for (uint256 i; i < actors.length; ++i) {
            registry.settle(actors[i]);
        }
        executed["settleAll"]++;
    }

    // --- keepers ---------------------------------------------------------------------

    /// @dev Resolves every due round of both assets, in order.
    function resolveDue(uint256 seed) external {
        for (uint256 asset; asset < 2; ++asset) {
            for (uint256 n; n < 5; ++n) {
                uint256 round = registry.assetState(asset).nextRoundToResolve;
                uint256 commitEnd = genesis + round * 1 days + window;
                uint256 resolveTime = commitEnd + 24 hours;
                if (vm.getBlockTimestamp() < resolveTime) break;
                _resolve(asset, round, commitEnd, resolveTime, seed);
            }
        }
        _revealOpen(seed);
    }

    function voidExpired(uint256 assetSeed) external {
        uint256 asset = bound(assetSeed, 0, 1);
        uint256 round = registry.assetState(asset).nextRoundToResolve;
        uint256 revealEnd = genesis + round * 1 days + window + 24 hours + registry.revealWindow();
        if (vm.getBlockTimestamp() < revealEnd) return;
        registry.voidExpiredRound(asset, round);
        ghostVoidedCommits += registry.roundInfo(asset, round).commitments;
        executed["void"]++;
    }

    function finalize(uint256 assetSeed, uint256 roundsBack) external {
        uint256 asset = bound(assetSeed, 0, 1);
        uint256 current = registry.currentRound();
        uint256 back = bound(roundsBack, 3, 6);
        if (current < back) return;
        ForecastRegistry.Round memory r = registry.roundInfo(asset, current - back);
        bool settled =
            r.status == ForecastRegistry.RoundStatus.Resolved || r.status == ForecastRegistry.RoundStatus.Voided;
        if (!settled || r.finalized || vm.getBlockTimestamp() < r.revealEnd) return;
        registry.finalizeRound(asset, current - back);
        executed["finalize"]++;
    }

    function warp(uint256 seconds_) external {
        vm.warp(vm.getBlockTimestamp() + bound(seconds_, 1 minutes, 30 hours));
    }

    // --- helpers ---------------------------------------------------------------------

    /// @dev Reveals every commitment whose reveal window is open now, except the forgotten ones.
    function _revealOpen(uint256 seed) internal {
        uint256 current = registry.currentRound();
        for (uint256 back = 1; back <= 3 && back <= current; ++back) {
            uint256 round = current - back;
            for (uint256 asset; asset < 2; ++asset) {
                ForecastRegistry.Round memory r = registry.roundInfo(asset, round);
                if (r.status == ForecastRegistry.RoundStatus.None) continue;
                if (vm.getBlockTimestamp() < r.resolveTime || vm.getBlockTimestamp() >= r.revealEnd) continue;
                for (uint256 i; i < actors.length; ++i) {
                    _reveal(actors[i], asset, round, seed);
                }
            }
        }
    }

    function _commit(address actor, uint256 asset, uint256 round, uint256 forecast) internal {
        bytes32 hash = registry.commitmentHash(asset, round, actor, forecast, _salt(actor, asset, round));
        vm.prank(actor);
        registry.commit(asset, round, hash);
        uint256 weight = registry.commitmentOf(asset, round, actor).weight;
        if (weight < 1e18 || weight > 2e18) ghostWeightOutOfBounds = true;
        committed[actor][asset][round] = forecast + 1;
        ++ghostCommits;
        executed["commit"]++;
    }

    function _reveal(address actor, uint256 asset, uint256 round, uint256 seed) internal {
        uint256 stored = committed[actor][asset][round];
        if (stored == 0 || registry.commitmentOf(asset, round, actor).revealed) return;
        if (uint256(keccak256(abi.encode(seed, actor, asset, round))) % 8 == 0) return; // forgotten
        vm.prank(actor);
        registry.reveal(asset, round, stored - 1, _salt(actor, asset, round));
        executed["reveal"]++;
    }

    function _resolve(uint256 asset, uint256 round, uint256 commitEnd, uint256 resolveTime, uint256 seed) internal {
        uint80 refHint = _publish(asset, commitEnd, lastPrice[asset]);

        // Produce the planned outcome when there is one, otherwise a random move within 6%.
        uint256 planned = plannedOutcome[asset][round];
        uint256 threshold = registry.roundInfo(asset, round).status == ForecastRegistry.RoundStatus.None
            ? registry.assetState(asset).threshold
            : registry.roundInfo(asset, round).threshold;
        uint256 moveWad = planned == 2
            ? threshold * 3 / 2
            : planned == 1 ? threshold / 2 : uint256(keccak256(abi.encode(seed, asset, round))) % 0.06e18;
        bool up = uint256(keccak256(abi.encode(seed, round, asset))) % 2 == 0;
        int256 move = int256(moveWad) * lastPrice[asset] / 1e18;
        int256 closePrice = up ? lastPrice[asset] + move : lastPrice[asset] - move;
        uint80 closeHint = _publish(asset, resolveTime, closePrice);
        lastPrice[asset] = closePrice;

        registry.resolveRound(
            asset, round, ForecastRegistry.PriceHints(refHint, sequencerRound, closeHint, sequencerRound)
        );
        if (round > maxRoundTouched) maxRoundTouched = round;
        executed["resolve"]++;
    }

    /// @dev Publishes a price at `time` once; later calls reuse the same Chainlink round.
    function _publish(uint256 asset, uint256 time, int256 price) internal returns (uint80 hint) {
        hint = published[asset][time];
        if (hint != 0) return hint;
        hint = feeds[asset].push(price, time, time);
        published[asset][time] = hint;
    }

    function _salt(address actor, uint256 asset, uint256 round) internal pure returns (bytes32) {
        return keccak256(abi.encode(actor, asset, round));
    }
}
