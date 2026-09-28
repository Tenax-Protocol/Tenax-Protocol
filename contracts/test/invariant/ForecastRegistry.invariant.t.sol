// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {ForecastTestBase} from "../utils/ForecastTestBase.sol";
import {ForecastHandler} from "./handlers/ForecastHandler.sol";
import {console} from "forge-std/Test.sol";

/// forge-config: default.invariant.depth = 300
/// forge-config: default.invariant.runs = 64
/// forge-config: ci.invariant.depth = 400
/// forge-config: ci.invariant.runs = 128
contract ForecastRegistryInvariantTest is ForecastTestBase {
    ForecastHandler internal handler;

    function setUp() public override {
        super.setUp();
        address[] memory actors = new address[](6);
        for (uint256 i; i < actors.length; ++i) {
            actors[i] = makeAddr(string.concat("forecaster-", vm.toString(i)));
            votes.setVotes(actors[i], 5000e18);
        }
        handler = new ForecastHandler(registry, btcFeed, ethFeed, sequencerRound, actors);
        targetContract(address(handler));
    }

    /// @dev Every commitment is scored at most once: scored plus pending never exceeds commitments, and only
    /// commitments of voided rounds can be missing.
    function invariant_eachCommitmentScoredAtMostOnce() public view {
        uint256 accounted;
        uint256 lastSeason = registry.seasonOf(handler.maxRoundTouched());
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            accounted += registry.pendingCount(actor);
            for (uint256 s; s <= lastSeason; ++s) {
                accounted += registry.seasonStats(actor, s).rounds;
            }
        }
        assertLe(accounted, handler.ghostCommits());
        assertGe(accounted, handler.ghostCommits() - handler.ghostVoidedCommits());
    }

    /// @dev The reward denominator always equals the sum of what each participant contributes.
    function invariant_contributionTotalsMatchParticipants() public view {
        uint256 lastSeason = registry.seasonOf(handler.maxRoundTouched()) + 2;
        for (uint256 s; s <= lastSeason; ++s) {
            uint256 sum;
            for (uint256 i; i < handler.actorCount(); ++i) {
                sum += registry.seasonStats(handler.actors(i), s).contribution;
            }
            assertEq(registry.totalContribution(s), sum);
        }
    }

    /// @dev Contributions are only counted for eligible participants.
    function invariant_contributionsRequireEligibility() public view {
        uint256 lastSeason = registry.seasonOf(handler.maxRoundTouched());
        for (uint256 i; i < handler.actorCount(); ++i) {
            address actor = handler.actors(i);
            for (uint256 s; s <= lastSeason; ++s) {
                if (registry.seasonStats(actor, s).contribution != 0) assertTrue(registry.isEligible(actor, s));
            }
        }
    }

    function invariant_weightsStayWithinBounds() public view {
        assertFalse(handler.ghostWeightOutOfBounds());
    }

    function invariant_reputationStaysWithinSkillRange() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            int256 ema = registry.reputation(handler.actors(i));
            assertGe(ema, -1e8);
            assertLe(ema, 1e8);
        }
    }

    function invariant_pendingListsStayBounded() public view {
        for (uint256 i; i < handler.actorCount(); ++i) {
            assertLe(registry.pendingCount(handler.actors(i)), registry.MAX_PENDING());
        }
    }

    function invariant_assetStateStaysValid() public view {
        for (uint256 asset; asset < 2; ++asset) {
            ForecastRegistry.AssetState memory state = registry.assetState(asset);
            assertGt(state.threshold, 0);
            assertLe(state.baseRate, 1e18);
        }
    }

    /// @dev Finalized aggregates are probabilities.
    function invariant_aggregatesAreProbabilities() public view {
        uint256 last = handler.maxRoundTouched();
        for (uint256 asset; asset < 2; ++asset) {
            for (uint256 round; round <= last; ++round) {
                ForecastRegistry.Round memory r = registry.roundInfo(asset, round);
                assertLe(r.aggregateBps, 10_000);
                assertLe(r.baseRateBps, 10_000);
                assertLe(r.reveals, r.commitments);
            }
        }
    }

    function afterInvariant() external view {
        string[7] memory operations = ["commitRound", "commit", "reveal", "resolve", "void", "finalize", "settleAll"];
        for (uint256 i; i < operations.length; ++i) {
            console.log(operations[i], handler.executed(operations[i]));
        }
        console.log("rounds touched", handler.maxRoundTouched());
        uint256 eligible;
        for (uint256 i; i < handler.actorCount(); ++i) {
            if (registry.seasonStats(handler.actors(i), 0).contribution != 0) ++eligible;
        }
        console.log("eligible in season 0", eligible);
    }
}
