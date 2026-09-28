// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3, OracleAdapter} from "../../src/forecast/OracleAdapter.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {ForecastTestBase} from "../utils/ForecastTestBase.sol";

contract OracleAdapterTest is ForecastTestBase {
    uint256 internal t;

    function setUp() public override {
        super.setUp();
        t = GENESIS + 10 days;
        vm.warp(t + 1 days);
    }

    function test_priceAt_returnsTheRoundActiveAtTheTimestamp() public {
        _publish(BTC, 60_000e8, t - 2 hours);
        uint80 active = _publish(BTC, 61_000e8, t - 10 minutes);
        _publish(BTC, 62_000e8, t + 5 minutes);

        (bool valid, uint256 price) = oracle.priceAt(BTC, t, active, sequencerRound);
        assertTrue(valid);
        assertEq(price, 61_000e18);
    }

    function test_priceAt_acceptsARoundPublishedExactlyAtTheTimestamp() public {
        uint80 active = _publish(BTC, 61_000e8, t);
        (bool valid, uint256 price) = oracle.priceAt(BTC, t, active, sequencerRound);
        assertTrue(valid);
        assertEq(price, 61_000e18);
    }

    function test_priceAt_acceptsTheLatestRound() public {
        uint80 latest = _publish(BTC, 61_000e8, t - 10 minutes);
        (bool valid,) = oracle.priceAt(BTC, t, latest, sequencerRound);
        assertTrue(valid);
    }

    function test_priceAt_normalizesDecimals() public {
        MockAggregator sixDecimals = new MockAggregator(6);
        IAggregatorV3[] memory feeds = new IAggregatorV3[](1);
        feeds[0] = sixDecimals;
        uint64[] memory tolerances = new uint64[](1);
        tolerances[0] = uint64(STALENESS);
        OracleAdapter adapter = new OracleAdapter(feeds, tolerances, sequencer, GRACE);

        uint80 round = sixDecimals.push(2500e6, t, t);
        (, uint256 price) = adapter.priceAt(0, t, round, sequencerRound);
        assertEq(price, 2500e18);
    }

    function test_priceAt_isInvalidWhenStale() public {
        uint80 old = _publish(BTC, 61_000e8, t - STALENESS - 1);
        (bool valid, uint256 price) = oracle.priceAt(BTC, t, old, sequencerRound);
        assertFalse(valid);
        assertEq(price, 0);
    }

    function test_priceAt_isValidAtTheStalenessLimit() public {
        uint80 old = _publish(BTC, 61_000e8, t - STALENESS);
        (bool valid,) = oracle.priceAt(BTC, t, old, sequencerRound);
        assertTrue(valid);
    }

    function test_priceAt_isInvalidWhenNotPositive() public {
        uint80 zero = _publish(BTC, 0, t);
        (bool valid,) = oracle.priceAt(BTC, t, zero, sequencerRound);
        assertFalse(valid);
    }

    function test_priceAt_isInvalidWhenSequencerWasDown() public {
        uint80 price = _publish(BTC, 61_000e8, t);
        uint80 down = sequencer.push(1, t - 30 minutes, t - 30 minutes);
        sequencer.push(0, t + 1 hours, t + 1 hours);

        (bool valid,) = oracle.priceAt(BTC, t, price, down);
        assertFalse(valid);
    }

    function test_priceAt_isInvalidDuringSequencerGracePeriod() public {
        uint80 price = _publish(BTC, 61_000e8, t);
        sequencer.push(1, t - 3 hours, t - 3 hours);
        uint80 backUp = sequencer.push(0, t - 30 minutes, t - 30 minutes);

        (bool valid,) = oracle.priceAt(BTC, t, price, backUp);
        assertFalse(valid);
    }

    function test_priceAt_isValidAfterSequencerGracePeriod() public {
        uint80 price = _publish(BTC, 61_000e8, t);
        sequencer.push(1, t - 3 hours, t - 3 hours);
        uint80 backUp = sequencer.push(0, t - GRACE, t - GRACE);

        (bool valid,) = oracle.priceAt(BTC, t, price, backUp);
        assertTrue(valid);
    }

    function test_priceAt_skipsSequencerCheckWhenDisabled() public {
        IAggregatorV3[] memory feeds = new IAggregatorV3[](1);
        feeds[0] = btcFeed;
        uint64[] memory tolerances = new uint64[](1);
        tolerances[0] = uint64(STALENESS);
        OracleAdapter adapter = new OracleAdapter(feeds, tolerances, IAggregatorV3(address(0)), GRACE);

        uint80 price = _publish(BTC, 61_000e8, t);
        (bool valid,) = adapter.priceAt(0, t, price, 999);
        assertTrue(valid);
    }

    function test_RevertWhen_hintIsAfterTheTimestamp() public {
        _publish(BTC, 61_000e8, t - 10 minutes);
        uint80 later = _publish(BTC, 62_000e8, t + 5 minutes);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), later));
        oracle.priceAt(BTC, t, later, sequencerRound);
    }

    function test_RevertWhen_hintIsAnOlderRound() public {
        uint80 older = _publish(BTC, 60_000e8, t - 2 hours);
        _publish(BTC, 61_000e8, t - 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), older));
        oracle.priceAt(BTC, t, older, sequencerRound);
    }

    function test_RevertWhen_hintDoesNotExist() public {
        _publish(BTC, 61_000e8, t - 10 minutes);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), uint80(7)));
        oracle.priceAt(BTC, t, 7, sequencerRound);
    }

    function test_hintChecks_workWhenMissingRoundsReturnZeros() public {
        btcFeed.setRevertOnMissingRound(false);
        uint80 latest = _publish(BTC, 61_000e8, t - 10 minutes);
        (bool valid,) = oracle.priceAt(BTC, t, latest, sequencerRound);
        assertTrue(valid);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), uint80(9)));
        oracle.priceAt(BTC, t, 9, sequencerRound);
    }

    /// @dev When Chainlink upgrades a feed, proxy round ids jump to a new phase. The last round of the old phase
    /// has no "next" round and is not the latest, so it cannot be proven active; such a checkpoint cannot be
    /// priced and its round will expire and be voided.
    function test_RevertWhen_hintIsTheLastRoundOfAnOldPhase() public {
        uint80 oldPhaseLast = _publish(BTC, 61_000e8, t - 10 minutes);
        btcFeed.pushWithId(uint80(2 << 64) + 1, 62_000e8, t + 20 minutes, t + 20 minutes);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), oldPhaseLast));
        oracle.priceAt(BTC, t, oldPhaseLast, sequencerRound);

        (bool valid, uint256 price) = oracle.priceAt(BTC, t + 30 minutes, uint80(2 << 64) + 1, sequencerRound);
        assertTrue(valid);
        assertEq(price, 62_000e18);
    }

    function test_RevertWhen_sequencerHintIsWrong() public {
        uint80 price = _publish(BTC, 61_000e8, t);
        sequencer.push(0, t - 2 hours, t - 2 hours); // a newer status round exists before t
        vm.expectRevert(
            abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(sequencer), sequencerRound)
        );
        oracle.priceAt(BTC, t, price, sequencerRound);
    }

    function test_RevertWhen_timestampIsInTheFuture() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.FutureTimestamp.selector, vm.getBlockTimestamp() + 1));
        oracle.priceAt(BTC, vm.getBlockTimestamp() + 1, 1, sequencerRound);
    }

    function test_RevertWhen_assetIsUnknown() public {
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnknownAsset.selector, 2));
        oracle.priceAt(2, t, 1, sequencerRound);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnknownAsset.selector, 2));
        oracle.feed(2);
    }

    function test_feed_andAssetCount() public view {
        assertEq(oracle.assetCount(), 2);
        OracleAdapter.Feed memory f = oracle.feed(ETH);
        assertEq(address(f.aggregator), address(ethFeed));
        assertEq(f.stalenessTolerance, STALENESS);
        assertEq(f.decimals, 8);
    }

    function test_RevertWhen_constructorArgumentsAreInvalid() public {
        IAggregatorV3[] memory feeds = new IAggregatorV3[](1);
        uint64[] memory tolerances = new uint64[](2);
        vm.expectRevert(OracleAdapter.LengthMismatch.selector);
        new OracleAdapter(feeds, tolerances, sequencer, GRACE);

        tolerances = new uint64[](1);
        vm.expectRevert(OracleAdapter.ZeroAddress.selector);
        new OracleAdapter(feeds, tolerances, sequencer, GRACE);

        feeds[0] = new MockAggregator(19);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.UnsupportedDecimals.selector, 19));
        new OracleAdapter(feeds, tolerances, sequencer, GRACE);
    }
}
