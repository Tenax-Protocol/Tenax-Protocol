// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IAggregatorV3, OracleAdapter} from "../../src/forecast/OracleAdapter.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Runs the oracle adapter against live Chainlink feeds on Base mainnet, to check the round-hint logic
/// with real proxy round ids. Skipped unless BASE_RPC_URL is set. Feed addresses come from Chainlink's data feed
/// directory and can be overridden with BTC_USD_FEED, ETH_USD_FEED and SEQUENCER_FEED.
contract OracleAdapterForkTest is Test {
    uint256 internal constant STALENESS = 1320; // 1,200 s heartbeat + 10%
    uint256 internal constant GRACE = 1 hours;

    IAggregatorV3 internal btcFeed;
    IAggregatorV3 internal ethFeed;
    IAggregatorV3 internal sequencer;
    OracleAdapter internal adapter;

    function setUp() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true);
            return;
        }
        vm.createSelectFork(rpc);

        btcFeed = IAggregatorV3(vm.envOr("BTC_USD_FEED", address(0x32F587986D3fb47601157c19615d568BeD0BCabc)));
        ethFeed = IAggregatorV3(vm.envOr("ETH_USD_FEED", address(0xa4250cE1aA15Ff4cb5E5a8655293b65694e436Ed)));
        sequencer = IAggregatorV3(vm.envOr("SEQUENCER_FEED", address(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433)));

        IAggregatorV3[] memory feeds = new IAggregatorV3[](2);
        feeds[0] = btcFeed;
        feeds[1] = ethFeed;
        uint64[] memory tolerances = new uint64[](2);
        tolerances[0] = uint64(STALENESS);
        tolerances[1] = uint64(STALENESS);
        adapter = new OracleAdapter(feeds, tolerances, sequencer, GRACE);
    }

    function testFork_priceAtAPastTimestamp() public view {
        uint256 timestamp = vm.getBlockTimestamp() - 3 hours;
        uint80 sequencerRound = _roundAt(sequencer, timestamp, true);

        (bool btcValid, uint256 btcPrice) =
            adapter.priceAt(0, timestamp, _roundAt(btcFeed, timestamp, false), sequencerRound);
        (bool ethValid, uint256 ethPrice) =
            adapter.priceAt(1, timestamp, _roundAt(ethFeed, timestamp, false), sequencerRound);

        assertTrue(btcValid && ethValid);
        assertGt(btcPrice, 1000e18);
        assertLt(btcPrice, 10_000_000e18);
        assertGt(ethPrice, 100e18);
        assertLt(ethPrice, 1_000_000e18);
    }

    function testFork_neighbouringRoundsAreRejected() public {
        uint256 timestamp = vm.getBlockTimestamp() - 3 hours;
        uint80 sequencerRound = _roundAt(sequencer, timestamp, true);
        uint80 hint = _roundAt(btcFeed, timestamp, false);

        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), hint - 1));
        adapter.priceAt(0, timestamp, hint - 1, sequencerRound);
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), hint + 1));
        adapter.priceAt(0, timestamp, hint + 1, sequencerRound);
    }

    /// @dev Walks back from the latest round to the one active at `timestamp`, as a keeper would off-chain.
    function _roundAt(IAggregatorV3 aggregator, uint256 timestamp, bool useStartedAt) internal view returns (uint80) {
        (uint80 roundId,, uint256 startedAt, uint256 updatedAt,) = aggregator.latestRoundData();
        for (uint256 i; i < 500; ++i) {
            if ((useStartedAt ? startedAt : updatedAt) <= timestamp) return roundId;
            --roundId;
            (,, startedAt, updatedAt,) = aggregator.getRoundData(roundId);
        }
        revert("round not found within 500 steps");
    }
}
