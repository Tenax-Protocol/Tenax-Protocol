// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {BrierMath} from "../../src/forecast/BrierMath.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {OracleAdapter} from "../../src/forecast/OracleAdapter.sol";
import {ForecastTestBase} from "../utils/ForecastTestBase.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract ForecastRegistryTest is ForecastTestBase {
    // --- deployment and governance -------------------------------------------------

    function test_constructor_setsInitialState() public view {
        assertEq(registry.assetCount(), 2);
        assertEq(registry.genesis(), GENESIS);
        assertEq(registry.submissionWindow(), SUBMISSION_WINDOW);
        assertEq(registry.revealWindow(), REVEAL_WINDOW);
        ForecastRegistry.AssetState memory state = registry.assetState(BTC);
        assertEq(state.threshold, INITIAL_X);
        assertEq(state.baseRate, INITIAL_B);
        assertEq(state.nextRoundToResolve, 0);
    }

    function test_RevertWhen_constructorArgumentsAreInvalid() public {
        uint256[] memory two = new uint256[](2);
        two[0] = INITIAL_X;
        two[1] = INITIAL_X;
        uint256[] memory one = new uint256[](1);

        vm.expectRevert(ForecastRegistry.ZeroAddress.selector);
        new ForecastRegistry(IVotes(address(0)), oracle, governance, GENESIS, 30 minutes, 48 hours, two, two);

        vm.expectRevert(ForecastRegistry.LengthMismatch.selector);
        new ForecastRegistry(IVotes(address(votes)), oracle, governance, GENESIS, 30 minutes, 48 hours, one, two);

        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.OutOfBounds.selector, 1 minutes));
        new ForecastRegistry(IVotes(address(votes)), oracle, governance, GENESIS, 1 minutes, 48 hours, two, two);

        uint256[] memory badRates = new uint256[](2);
        badRates[1] = 1e18 + 1;
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.OutOfBounds.selector, 1e18 + 1));
        new ForecastRegistry(IVotes(address(votes)), oracle, governance, GENESIS, 30 minutes, 48 hours, two, badRates);

        uint256[] memory zeroThresholds = new uint256[](2);
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.OutOfBounds.selector, 0));
        new ForecastRegistry(
            IVotes(address(votes)), oracle, governance, GENESIS, 30 minutes, 48 hours, zeroThresholds, two
        );
    }

    function test_governance_setsWindowsWithinBounds() public {
        vm.startPrank(governance);
        registry.setSubmissionWindow(1 hours);
        registry.setRevealWindow(3 days);
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.OutOfBounds.selector, 7 hours));
        registry.setSubmissionWindow(7 hours);
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.OutOfBounds.selector, 8 days));
        registry.setRevealWindow(8 days);
        vm.stopPrank();
        assertEq(registry.submissionWindow(), 1 hours);
        assertEq(registry.revealWindow(), 3 days);
    }

    function test_RevertWhen_nonGovernanceSetsWindows() public {
        vm.expectRevert(ForecastRegistry.NotGovernance.selector);
        registry.setSubmissionWindow(1 hours);
        vm.expectRevert(ForecastRegistry.NotGovernance.selector);
        registry.setRevealWindow(3 days);
    }

    function test_windowChanges_applyOnlyToRoundsOpenedLater() public {
        _commit(alice, BTC, 0, 5000);
        vm.prank(governance);
        registry.setRevealWindow(3 days);
        assertEq(registry.roundInfo(BTC, 0).revealEnd, _revealEnd(0));

        vm.warp(_openTime(1));
        _commit(alice, BTC, 1, 5000);
        assertEq(registry.roundInfo(BTC, 1).revealEnd, _resolveTime(1) + 3 days);
    }

    function test_RevertWhen_beforeGenesis() public {
        vm.warp(GENESIS - 1);
        vm.expectRevert(ForecastRegistry.NotStarted.selector);
        registry.currentRound();
    }

    // --- commit --------------------------------------------------------------------

    function test_commit_opensRoundWithSnapshot() public {
        _commit(alice, BTC, 0, 5000);

        ForecastRegistry.Round memory r = registry.roundInfo(BTC, 0);
        assertEq(uint256(r.status), uint256(ForecastRegistry.RoundStatus.Open));
        assertEq(r.threshold, INITIAL_X);
        assertEq(r.baseRateBps, 3600);
        assertEq(r.commitEnd, _commitEnd(0));
        assertEq(r.resolveTime, _resolveTime(0));
        assertEq(r.revealEnd, _revealEnd(0));
        assertEq(r.commitments, 1);

        ForecastRegistry.Commitment memory c = registry.commitmentOf(BTC, 0, alice);
        assertEq(c.weight, 1e18, "a newcomer weighs 1");
        assertFalse(c.revealed);
        assertEq(registry.pendingCount(alice), 1);
    }

    function test_RevertWhen_commitToUnknownAsset() public {
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.UnknownAsset.selector, 2));
        vm.prank(alice);
        registry.commit(2, 0, bytes32("x"));
    }

    function test_RevertWhen_commitToAnotherRound() public {
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.NotCurrentRound.selector, 1));
        vm.prank(alice);
        registry.commit(BTC, 1, bytes32("x"));
    }

    function test_RevertWhen_commitAfterSubmissionWindow() public {
        vm.warp(_commitEnd(0));
        vm.expectRevert(ForecastRegistry.SubmissionClosed.selector);
        vm.prank(alice);
        registry.commit(BTC, 0, bytes32("x"));
    }

    function test_RevertWhen_votingPowerBelowMinimum() public {
        votes.setVotes(alice, 5000e18 - 1);
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.InsufficientVotingPower.selector, 5000e18 - 1));
        vm.prank(alice);
        registry.commit(BTC, 0, bytes32("x"));
    }

    function test_RevertWhen_committingTwice() public {
        _commit(alice, BTC, 0, 5000);
        vm.expectRevert(ForecastRegistry.AlreadyCommitted.selector);
        vm.prank(alice);
        registry.commit(BTC, 0, bytes32("x"));
    }

    // --- reveal --------------------------------------------------------------------

    function test_reveal_addsToTheAggregate() public {
        _commit(alice, BTC, 0, 7000);
        _commit(bob, BTC, 0, 3000);
        vm.warp(_resolveTime(0));
        _reveal(alice, BTC, 0, 7000);
        _reveal(bob, BTC, 0, 3000);

        ForecastRegistry.Round memory r = registry.roundInfo(BTC, 0);
        assertEq(r.reveals, 2);
        assertEq(r.weightSum, 2e18);
        assertEq(r.weightedForecastSum, 1e18 * 7000 + 1e18 * 3000);
        assertTrue(registry.commitmentOf(BTC, 0, alice).revealed);
        assertEq(registry.commitmentOf(BTC, 0, alice).forecast, 7000);
    }

    function test_RevertWhen_revealBeforeHorizonEnds() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_resolveTime(0) - 1);
        vm.expectRevert(ForecastRegistry.RevealNotOpen.selector);
        _reveal(alice, BTC, 0, 7000);
    }

    function test_RevertWhen_revealAfterRevealWindow() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_revealEnd(0));
        vm.expectRevert(ForecastRegistry.RevealClosed.selector);
        _reveal(alice, BTC, 0, 7000);
    }

    function test_RevertWhen_revealDoesNotMatchCommitment() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_resolveTime(0));
        vm.expectRevert(ForecastRegistry.CommitmentMismatch.selector);
        _reveal(alice, BTC, 0, 7001);
    }

    function test_RevertWhen_revealInvalidForecast() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_resolveTime(0));
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.InvalidForecast.selector, 10_001));
        _reveal(alice, BTC, 0, 10_001);
    }

    function test_RevertWhen_revealWithoutCommitment() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_resolveTime(0));
        vm.expectRevert(ForecastRegistry.NotCommitted.selector);
        _reveal(bob, BTC, 0, 7000);
    }

    function test_RevertWhen_revealTwice() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_resolveTime(0));
        _reveal(alice, BTC, 0, 7000);
        vm.expectRevert(ForecastRegistry.AlreadyRevealed.selector);
        _reveal(alice, BTC, 0, 7000);
    }

    function test_RevertWhen_revealUnopenedRound() public {
        vm.expectRevert(ForecastRegistry.RevealNotOpen.selector);
        _reveal(alice, BTC, 5, 7000);
    }

    function test_pendingList_isBoundedAndRecoversByVoidingExpiredRounds() public {
        // With no keeper resolving anything, 16 days of commits on both assets fill the list.
        for (uint256 round; round < 16; ++round) {
            vm.warp(_openTime(round));
            _commit(alice, BTC, round, 5000);
            _commit(alice, ETH, round, 5000);
        }
        assertEq(registry.pendingCount(alice), registry.MAX_PENDING());

        vm.warp(_openTime(16));
        bytes32 hash = registry.commitmentHash(BTC, 16, alice, 5000, bytes32(0));
        vm.expectRevert(ForecastRegistry.TooManyPending.selector);
        vm.prank(alice);
        registry.commit(BTC, 16, hash);

        // Anyone, including the participant, can void the expired rounds; the next commit drops them.
        for (uint256 round; round < 5; ++round) {
            registry.voidExpiredRound(BTC, round);
            registry.voidExpiredRound(ETH, round);
        }
        vm.prank(alice);
        registry.commit(BTC, 16, hash);
        assertEq(registry.pendingCount(alice), 32 - 10 + 1);
    }

    // --- resolution ----------------------------------------------------------------

    function test_resolveRound_largeMoveResolvesTrueAndUpdatesState() public {
        _commit(alice, BTC, 0, 7000);
        _resolveWith(BTC, 0, 100_000e8, 103_000e8); // |r| = 3% > X = 2%

        ForecastRegistry.Round memory r = registry.roundInfo(BTC, 0);
        assertEq(uint256(r.status), uint256(ForecastRegistry.RoundStatus.Resolved));
        assertTrue(r.outcome);
        assertEq(r.refPrice, 100_000e18);
        assertEq(r.closePrice, 103_000e18);

        ForecastRegistry.AssetState memory state = registry.assetState(BTC);
        assertEq(state.threshold, BrierMath.updateThreshold(INITIAL_X, 0.03e18));
        assertEq(state.baseRate, BrierMath.updateBaseRate(INITIAL_B, true));
        assertEq(state.nextRoundToResolve, 1);
    }

    function test_resolveRound_smallMoveResolvesFalse() public {
        _commit(alice, BTC, 0, 7000);
        _resolveWith(BTC, 0, 100_000e8, 99_000e8); // |r| = 1% < X
        assertFalse(registry.roundInfo(BTC, 0).outcome);
        assertEq(registry.assetState(BTC).baseRate, BrierMath.updateBaseRate(INITIAL_B, false));
    }

    function test_resolveRound_worksWithoutCommitments() public {
        vm.warp(_resolveTime(0));
        _resolveWith(BTC, 0, 100_000e8, 105_000e8);
        ForecastRegistry.Round memory r = registry.roundInfo(BTC, 0);
        assertEq(uint256(r.status), uint256(ForecastRegistry.RoundStatus.Resolved));
        assertEq(r.commitEnd, _commitEnd(0), "late opening keeps the scheduled times");
    }

    function test_resolveRound_voidsOnStalePrice() public {
        _commit(alice, BTC, 0, 7000);
        uint80 refRound = _publish(BTC, 100_000e8, _commitEnd(0) - STALENESS - 1);
        uint80 closeRound = _publish(BTC, 103_000e8, _resolveTime(0));
        vm.warp(_resolveTime(0));
        registry.resolveRound(BTC, 0, _hints(refRound, closeRound));

        assertEq(uint256(registry.roundInfo(BTC, 0).status), uint256(ForecastRegistry.RoundStatus.Voided));
        assertEq(registry.assetState(BTC).threshold, INITIAL_X, "a voided round does not move X");
        assertEq(registry.assetState(BTC).nextRoundToResolve, 1);
    }

    function test_resolveRound_voidsWhenSequencerWasDown() public {
        _commit(alice, BTC, 0, 7000);
        uint80 refRound = _publish(BTC, 100_000e8, _commitEnd(0));
        uint80 closeRound = _publish(BTC, 103_000e8, _resolveTime(0));
        uint80 down = sequencer.push(1, _resolveTime(0) - 10 minutes, _resolveTime(0) - 10 minutes);
        sequencer.push(0, _resolveTime(0) + 1 hours, _resolveTime(0) + 1 hours);
        vm.warp(_resolveTime(0) + 2 hours);

        registry.resolveRound(BTC, 0, ForecastRegistry.PriceHints(refRound, sequencerRound, closeRound, down));
        assertEq(uint256(registry.roundInfo(BTC, 0).status), uint256(ForecastRegistry.RoundStatus.Voided));
    }

    function test_RevertWhen_resolvingOutOfOrder() public {
        vm.warp(_resolveTime(1));
        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.NotNextRound.selector, 0));
        registry.resolveRound(BTC, 1, _hints(1, 1));
    }

    function test_RevertWhen_resolvingBeforeResolveTime() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_resolveTime(0) - 1);
        vm.expectRevert(ForecastRegistry.NotResolvable.selector);
        registry.resolveRound(BTC, 0, _hints(1, 1));
    }

    function test_RevertWhen_resolvingARoundThatHasNotOpened() public {
        _resolveWith(BTC, 0, 100_000e8, 101_000e8);
        vm.warp(_openTime(1) - 1);
        vm.expectRevert(ForecastRegistry.NotResolvable.selector);
        registry.resolveRound(BTC, 1, _hints(1, 1));
    }

    function test_RevertWhen_resolvingWithWrongHints() public {
        _commit(alice, BTC, 0, 7000);
        uint80 refRound = _publish(BTC, 100_000e8, _commitEnd(0));
        uint80 closeRound = _publish(BTC, 103_000e8, _resolveTime(0));
        vm.warp(_resolveTime(0));
        vm.expectRevert(abi.encodeWithSelector(OracleAdapter.WrongRoundHint.selector, address(btcFeed), refRound));
        registry.resolveRound(BTC, 0, _hints(refRound, refRound));
        registry.resolveRound(BTC, 0, _hints(refRound, closeRound));
    }

    function test_roundsResolveIndependentlyPerAsset() public {
        vm.warp(_resolveTime(0));
        _resolveWith(ETH, 0, 3000e8, 3100e8);
        assertEq(registry.assetState(ETH).nextRoundToResolve, 1);
        assertEq(registry.assetState(BTC).nextRoundToResolve, 0);
    }

    // --- voiding and finalization ----------------------------------------------------

    function test_voidExpiredRound_afterRevealWindow() public {
        _commit(alice, BTC, 0, 7000);
        vm.warp(_revealEnd(0) - 1);
        vm.expectRevert(ForecastRegistry.NotExpired.selector);
        registry.voidExpiredRound(BTC, 0);

        vm.warp(_revealEnd(0));
        registry.voidExpiredRound(BTC, 0);
        assertEq(uint256(registry.roundInfo(BTC, 0).status), uint256(ForecastRegistry.RoundStatus.Voided));
        assertEq(registry.assetState(BTC).nextRoundToResolve, 1);

        vm.expectRevert(abi.encodeWithSelector(ForecastRegistry.NotNextRound.selector, 1));
        registry.voidExpiredRound(BTC, 0);
    }

    function test_finalizeRound_publishesWeightedAggregate() public {
        _commit(alice, BTC, 0, 8000);
        _commit(bob, BTC, 0, 2000);
        _resolveWith(BTC, 0, 100_000e8, 103_000e8);
        _reveal(alice, BTC, 0, 8000);
        _reveal(bob, BTC, 0, 2000);

        vm.warp(_revealEnd(0));
        registry.finalizeRound(BTC, 0);
        ForecastRegistry.Round memory r = registry.roundInfo(BTC, 0);
        assertTrue(r.finalized);
        assertEq(r.aggregateBps, 5000);

        vm.expectRevert(ForecastRegistry.NotFinalizable.selector);
        registry.finalizeRound(BTC, 0);
    }

    function test_finalizeRound_weightsFollowReputation() public {
        // Give alice a strong record first.
        _playRounds(alice, 0, 5, 10_000, true);
        uint256 round = 5;
        vm.warp(_openTime(round));
        _commit(alice, BTC, round, 9000);
        _commit(bob, BTC, round, 1000);
        uint256 aliceWeight = registry.commitmentOf(BTC, round, alice).weight;
        assertGt(aliceWeight, 1e18);

        _resolveWith(BTC, round, 100_000e8, 104_000e8);
        _reveal(alice, BTC, round, 9000);
        _reveal(bob, BTC, round, 1000);
        vm.warp(_revealEnd(round));
        registry.finalizeRound(BTC, round);

        uint256 expected = (aliceWeight * 9000 + 1e18 * 1000) / (aliceWeight + 1e18);
        assertEq(registry.roundInfo(BTC, round).aggregateBps, expected);
    }

    function test_RevertWhen_finalizingEarlyOrUnresolved() public {
        _commit(alice, BTC, 0, 8000);
        vm.warp(_revealEnd(0) - 1);
        vm.expectRevert(ForecastRegistry.NotFinalizable.selector);
        registry.finalizeRound(BTC, 0);

        _resolveWith(BTC, 0, 100_000e8, 103_000e8);
        vm.expectRevert(ForecastRegistry.NotFinalizable.selector);
        registry.finalizeRound(BTC, 0);
    }

    function test_finalizeRound_voidedRoundHasNoAggregate() public {
        _commit(alice, BTC, 0, 8000);
        vm.warp(_revealEnd(0));
        registry.voidExpiredRound(BTC, 0);
        registry.finalizeRound(BTC, 0);
        assertEq(registry.roundInfo(BTC, 0).aggregateBps, 0);
    }

    // --- scoring ---------------------------------------------------------------------

    function test_reveal_scoresImmediatelyWhenResolved() public {
        _commit(alice, BTC, 0, 9000);
        _resolveWith(BTC, 0, 100_000e8, 103_000e8);
        _reveal(alice, BTC, 0, 9000);

        int256 expected = BrierMath.skill(9000, 3600, true);
        assertEq(registry.seasonStats(alice, 0).skillSum, expected);
        assertEq(registry.seasonStats(alice, 0).rounds, 1);
        assertEq(registry.reputation(alice), BrierMath.updateReputation(0, expected));
        assertEq(registry.pendingCount(alice), 0);
    }

    function test_reveal_beforeResolutionIsScoredLater() public {
        _commit(alice, BTC, 0, 9000);
        vm.warp(_resolveTime(0));
        _reveal(alice, BTC, 0, 9000);
        assertEq(registry.pendingCount(alice), 1, "still waiting for the outcome");

        _resolveWith(BTC, 0, 100_000e8, 103_000e8);
        registry.settle(alice);
        assertEq(registry.pendingCount(alice), 0);
        assertEq(registry.seasonStats(alice, 0).skillSum, BrierMath.skill(9000, 3600, true));
    }

    function test_settle_penalizesUnrevealedAfterWindow() public {
        _commit(alice, BTC, 0, 9000);
        _resolveWith(BTC, 0, 100_000e8, 103_000e8);

        registry.settle(alice);
        assertEq(registry.pendingCount(alice), 1, "reveal window still open");

        vm.warp(_revealEnd(0));
        registry.settle(alice);
        assertEq(registry.pendingCount(alice), 0);
        assertEq(registry.seasonStats(alice, 0).skillSum, BrierMath.missedRevealSkill(3600, true));
    }

    function test_settle_dropsVoidedRoundsWithoutScore() public {
        _commit(alice, BTC, 0, 9000);
        vm.warp(_revealEnd(0));
        registry.voidExpiredRound(BTC, 0);
        registry.settle(alice);
        assertEq(registry.pendingCount(alice), 0);
        assertEq(registry.seasonStats(alice, 0).rounds, 0);
    }

    function test_commit_settlesPendingPenalties() public {
        _commit(alice, BTC, 0, 9000);
        _resolveWith(BTC, 0, 100_000e8, 103_000e8);
        vm.warp(_openTime(4)); // after round 0's reveal window (3 days and 30 minutes after it opened)
        _commit(alice, BTC, 4, 5000);
        assertEq(registry.seasonStats(alice, 0).rounds, 1, "round 0 penalized on the next commit");
        assertEq(registry.pendingCount(alice), 1);
    }

    // --- seasons -----------------------------------------------------------------------

    function test_season_skilledForecasterBecomesEligible() public {
        _playRounds(alice, 0, 25, 10_000, true);
        assertTrue(registry.isEligible(alice, 0));
        int256 sum = registry.seasonStats(alice, 0).skillSum;
        assertEq(registry.seasonStats(alice, 0).contribution, uint256(sum));
        assertEq(registry.totalContribution(0), uint256(sum));
    }

    function test_season_needsTwentyRounds() public {
        _playRounds(alice, 0, 19, 10_000, true);
        assertFalse(registry.isEligible(alice, 0));
        assertEq(registry.totalContribution(0), 0);
    }

    function test_season_answeringTheBaseRateIsNeverEligible() public {
        for (uint256 round; round < 25; ++round) {
            vm.warp(_openTime(round));
            // The round copies b when it opens, so the current state is exactly what it will use.
            uint256 baseRate = BrierMath.toBps(registry.assetState(BTC).baseRate);
            _commit(alice, BTC, round, baseRate);
            assertEq(registry.roundInfo(BTC, round).baseRateBps, baseRate);
            _resolveWith(BTC, round, 100_000e8, round % 3 == 0 ? int256(105_000e8) : int256(100_500e8));
            _reveal(alice, BTC, round, baseRate);
        }
        assertEq(registry.seasonStats(alice, 0).skillSum, 0);
        assertEq(registry.seasonStats(alice, 0).skillSquares, 0);
        assertFalse(registry.isEligible(alice, 0));
    }

    function test_season_wrongForecasterLosesContribution() public {
        _playRounds(alice, 0, 22, 10_000, true);
        assertTrue(registry.isEligible(alice, 0));
        _playRounds(alice, 22, 8, 10_000, false); // confidently wrong
        assertFalse(registry.isEligible(alice, 0));
        assertEq(registry.totalContribution(0), 0);
    }

    function test_seasonOf() public view {
        assertEq(registry.seasonOf(0), 0);
        assertEq(registry.seasonOf(29), 0);
        assertEq(registry.seasonOf(30), 1);
    }

    // --- helpers -----------------------------------------------------------------------

    /// @dev Plays `count` consecutive BTC rounds from `firstRound`: `participant` forecasts `forecast`, prices move
    /// 5% (outcome true) or 0.5% (outcome false), and every round is resolved and revealed.
    function _playRounds(address participant, uint256 firstRound, uint256 count, uint256 forecast, bool outcome)
        internal
    {
        for (uint256 round = firstRound; round < firstRound + count; ++round) {
            vm.warp(_openTime(round));
            _commit(participant, BTC, round, forecast);
            int256 closePrice = outcome ? int256(105_000e8) : int256(100_500e8);
            _resolveWith(BTC, round, 100_000e8, closePrice);
            _reveal(participant, BTC, round, forecast);
        }
    }
}
