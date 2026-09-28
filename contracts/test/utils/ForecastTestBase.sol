// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {IAggregatorV3, OracleAdapter} from "../../src/forecast/OracleAdapter.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockVotes} from "../mocks/MockVotes.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Shared setup for forecasting tests: two assets (BTC = 0, ETH = 1) with mock Chainlink feeds, a sequencer
/// feed that has been up for a long time, and helpers to publish prices and walk through a round.
abstract contract ForecastTestBase is Test {
    uint256 internal constant BTC = 0;
    uint256 internal constant ETH = 1;
    uint256 internal constant GENESIS = 1_799_971_200; // a UTC midnight
    uint256 internal constant SUBMISSION_WINDOW = 30 minutes;
    uint256 internal constant REVEAL_WINDOW = 48 hours;
    uint256 internal constant STALENESS = 3960; // 1 h heartbeat + 10%
    uint256 internal constant GRACE = 1 hours;
    uint256 internal constant INITIAL_X = 0.02e18;
    uint256 internal constant INITIAL_B = 0.36e18;

    MockAggregator internal btcFeed;
    MockAggregator internal ethFeed;
    MockAggregator internal sequencer;
    OracleAdapter internal oracle;
    MockVotes internal votes;
    ForecastRegistry internal registry;
    address internal governance = makeAddr("governance");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal keeper = makeAddr("keeper");

    uint80 internal sequencerRound;

    function setUp() public virtual {
        vm.warp(GENESIS);
        btcFeed = new MockAggregator(8);
        ethFeed = new MockAggregator(8);
        sequencer = new MockAggregator(0);
        sequencerRound = sequencer.push(0, GENESIS - 30 days, GENESIS - 30 days);

        IAggregatorV3[] memory feeds = new IAggregatorV3[](2);
        feeds[0] = btcFeed;
        feeds[1] = ethFeed;
        uint64[] memory tolerances = new uint64[](2);
        tolerances[0] = uint64(STALENESS);
        tolerances[1] = uint64(STALENESS);
        oracle = new OracleAdapter(feeds, tolerances, sequencer, GRACE);

        votes = new MockVotes();
        uint256[] memory thresholds = new uint256[](2);
        thresholds[0] = INITIAL_X;
        thresholds[1] = 0.028e18;
        uint256[] memory baseRates = new uint256[](2);
        baseRates[0] = INITIAL_B;
        baseRates[1] = INITIAL_B;
        registry = new ForecastRegistry(
            IVotes(address(votes)), oracle, governance, GENESIS, SUBMISSION_WINDOW, REVEAL_WINDOW, thresholds, baseRates
        );

        votes.setVotes(alice, 5000e18);
        votes.setVotes(bob, 5000e18);
    }

    // --- schedule ----------------------------------------------------------------

    function _openTime(uint256 round) internal pure returns (uint256) {
        return GENESIS + round * 1 days;
    }

    function _commitEnd(uint256 round) internal pure returns (uint256) {
        return _openTime(round) + SUBMISSION_WINDOW;
    }

    function _resolveTime(uint256 round) internal pure returns (uint256) {
        return _commitEnd(round) + 24 hours;
    }

    function _revealEnd(uint256 round) internal pure returns (uint256) {
        return _resolveTime(round) + REVEAL_WINDOW;
    }

    // --- participants ------------------------------------------------------------

    function _salt(address participant, uint256 asset, uint256 round) internal pure returns (bytes32) {
        return keccak256(abi.encode("salt", participant, asset, round));
    }

    function _commit(address participant, uint256 asset, uint256 round, uint256 forecast) internal {
        bytes32 hash = registry.commitmentHash(asset, round, participant, forecast, _salt(participant, asset, round));
        vm.prank(participant);
        registry.commit(asset, round, hash);
    }

    function _reveal(address participant, uint256 asset, uint256 round, uint256 forecast) internal {
        bytes32 salt = _salt(participant, asset, round);
        vm.prank(participant);
        registry.reveal(asset, round, forecast, salt);
    }

    // --- prices ------------------------------------------------------------------

    function _feed(uint256 asset) internal view returns (MockAggregator) {
        return asset == BTC ? btcFeed : ethFeed;
    }

    /// @dev Publishes `price` (8 decimals) at exactly `time`; returns the round to use as a hint.
    function _publish(uint256 asset, int256 price, uint256 time) internal returns (uint80) {
        return _feed(asset).push(price, time, time);
    }

    function _hints(uint80 refRound, uint80 closeRound) internal view returns (ForecastRegistry.PriceHints memory) {
        return ForecastRegistry.PriceHints(refRound, sequencerRound, closeRound, sequencerRound);
    }

    /// @dev Publishes reference and closing prices for `round` and resolves it after its resolve time.
    function _resolveWith(uint256 asset, uint256 round, int256 refPrice, int256 closePrice) internal {
        uint80 refRound = _publish(asset, refPrice, _commitEnd(round));
        uint80 closeRound = _publish(asset, closePrice, _resolveTime(round));
        if (vm.getBlockTimestamp() < _resolveTime(round)) vm.warp(_resolveTime(round));
        vm.prank(keeper);
        registry.resolveRound(asset, round, _hints(refRound, closeRound));
    }
}
