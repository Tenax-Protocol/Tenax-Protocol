// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {IWETH, SeasonRewards} from "../../src/distribution/SeasonRewards.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {SeasonRewardsTestBase} from "../utils/SeasonRewardsTestBase.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract SeasonRewardsTest is SeasonRewardsTestBase {
    /// @dev Season 0: alice (30 rounds) and bob (20 rounds) forecast well; carol forecasts badly; dave plays
    /// only 19 rounds. Revenue arrives during seasons 0 and 1.
    function _playSeasonZero() internal {
        Player[] memory players = new Player[](4);
        players[0] = Player(alice, true, 0, 30);
        players[1] = Player(bob, true, 0, 20);
        players[2] = Player(carol, false, 0, 30);
        players[3] = Player(dave, true, 0, 19);
        _deposit(1 ether);
        _play(players, 0, 29);
        vm.warp(GENESIS + 31 days);
        _deposit(0.5 ether); // season 1 revenue
    }

    function _registerAndClose() internal {
        _playSeasonZero();
        _openRegistration(0);
        _register(alice, 0);
        _register(bob, 0);
        l1.setNumber(uint64(L1_START + EPOCH / 10));
        vm.warp(_closeTime(0));
        rewards.closeSeason(0);
    }

    // --- registration ------------------------------------------------------------

    function test_register_settlesAndRecordsTheFinalContribution() public {
        _playSeasonZero();
        // Alice's last reveal happened before the round was resolved, so it is still unscored.
        assertEq(registry.pendingCount(alice), 1);
        uint256 before = registry.seasonStats(alice, 0).contribution;

        _openRegistration(0);
        _register(alice, 0);

        assertEq(registry.pendingCount(alice), 0);
        ForecastRegistry.SeasonStats memory stats = registry.seasonStats(alice, 0);
        assertEq(stats.rounds, 30);
        assertGt(stats.contribution, before);
        assertEq(rewards.registrationOf(0, alice).contribution, stats.contribution);
        assertEq(rewards.seasonInfo(0).totalContribution, stats.contribution);
        assertEq(rewards.seasonInfo(0).participants, 1);
    }

    function test_RevertWhen_registeringBeforeEveryRevealWindowCanClose() public {
        _playSeasonZero();
        uint256 opensAt = rewards.registrationStart(0);
        assertEq(opensAt, GENESIS + 30 days + 6 hours + 24 hours + 7 days);
        vm.warp(opensAt - 1);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewards.RegistrationNotOpen.selector, opensAt));
        rewards.register(alice, 0);
    }

    function test_RevertWhen_registeringAfterThePeriod() public {
        _playSeasonZero();
        _openRegistration(0);
        vm.warp(_closeTime(0));
        vm.expectRevert(SeasonRewards.RegistrationClosed.selector);
        rewards.register(alice, 0);
    }

    function test_RevertWhen_roundsOfTheSeasonArePending() public {
        _playSeasonZero();
        vm.warp(rewards.registrationStart(0));
        // ETH rounds were never resolved nor voided.
        vm.expectRevert(abi.encodeWithSelector(SeasonRewards.RoundsPending.selector, ETH));
        rewards.register(alice, 0);

        _voidPending(ETH, 28);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewards.RoundsPending.selector, ETH));
        rewards.register(alice, 0);

        registry.voidExpiredRound(ETH, 29);
        rewards.register(alice, 0);
    }

    function test_RevertWhen_participantIsNotEligible() public {
        _playSeasonZero();
        _openRegistration(0);
        vm.expectRevert(SeasonRewards.NotEligible.selector);
        rewards.register(carol, 0); // negative skill
        vm.expectRevert(SeasonRewards.NotEligible.selector);
        rewards.register(dave, 0); // 19 rounds
        vm.expectRevert(SeasonRewards.NotEligible.selector);
        rewards.register(keeper, 0); // never played
    }

    function test_RevertWhen_registeringTwice() public {
        _playSeasonZero();
        _openRegistration(0);
        _register(alice, 0);
        vm.expectRevert(SeasonRewards.AlreadyRegistered.selector);
        rewards.register(alice, 0);
    }

    // --- closing -----------------------------------------------------------------

    function test_closeSeason_fixesTheBudget() public {
        _registerAndClose();
        SeasonRewards.Season memory s = rewards.seasonInfo(0);
        assertTrue(s.closed);
        assertEq(s.tenaxBudget, schedule.emittedUntil(L1_START + EPOCH / 10));
        assertEq(s.ethBudget, 1 ether, "only revenue received during the season");
        assertEq(
            s.totalContribution,
            rewards.registrationOf(0, alice).contribution + rewards.registrationOf(0, bob).contribution
        );
        assertEq(rewards.emissionsAssigned(), s.tenaxBudget);
        assertEq(rewards.nextSeasonToClose(), 1);
        assertEq(rewards.ethReceived(1), 0.5 ether);
    }

    function test_RevertWhen_closingEarlyOrOutOfOrder() public {
        uint256 closesAt = _closeTime(0);
        vm.warp(closesAt - 1);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewards.SeasonNotClosable.selector, closesAt));
        rewards.closeSeason(0);

        vm.warp(_closeTime(1));
        vm.expectRevert(abi.encodeWithSelector(SeasonRewards.NotNextSeason.selector, 0));
        rewards.closeSeason(1);
        rewards.closeSeason(0);
        vm.expectRevert(abi.encodeWithSelector(SeasonRewards.NotNextSeason.selector, 1));
        rewards.closeSeason(0);
    }

    function test_closeSeason_carriesTheBudgetWhenNobodyRegistered() public {
        // Nobody plays season 0; alice plays season 1 well and is the only one registered.
        _deposit(1 ether);
        Player[] memory players = new Player[](1);
        players[0] = Player(alice, true, 30, 60);
        _play(players, 0, 59);

        l1.setNumber(uint64(L1_START + EPOCH / 10));
        rewards.closeSeason(0);
        assertEq(rewards.seasonInfo(0).tenaxBudget, 0);
        assertEq(rewards.seasonInfo(0).ethBudget, 0);
        assertEq(rewards.tenaxCarry(), schedule.emittedUntil(L1_START + EPOCH / 10));
        assertEq(rewards.ethCarry(), 1 ether);

        _openRegistration(1);
        _register(alice, 1);
        l1.setNumber(uint64(L1_START + EPOCH / 5));
        vm.warp(_closeTime(1));
        rewards.closeSeason(1);

        SeasonRewards.Season memory s = rewards.seasonInfo(1);
        assertEq(s.tenaxBudget, schedule.emittedUntil(L1_START + EPOCH / 5));
        assertEq(s.ethBudget, 1 ether, "season 0 revenue carried over");
        assertEq(rewards.tenaxCarry(), 0);
        assertEq(rewards.ethCarry(), 0);

        vm.prank(alice);
        rewards.claim(1);
        (uint256 amount,,) = escrow.locked(alice);
        assertEq(amount, s.tenaxBudget, "sole participant receives the whole budget");
    }

    // --- claims ------------------------------------------------------------------

    function test_claim_paysSharesProportionalToContribution() public {
        _registerAndClose();
        SeasonRewards.Season memory s = rewards.seasonInfo(0);
        uint256 aliceContribution = rewards.registrationOf(0, alice).contribution;
        uint256 bobContribution = rewards.registrationOf(0, bob).contribution;
        assertGt(aliceContribution, bobContribution);

        (uint256 aliceTenax, uint256 aliceEth) = rewards.claimable(0, alice);
        assertEq(aliceTenax, s.tenaxBudget * aliceContribution / s.totalContribution);
        assertEq(aliceEth, s.ethBudget * aliceContribution / s.totalContribution);

        vm.prank(alice);
        rewards.claim(0);
        vm.prank(bob);
        rewards.claim(0);

        (uint256 bobTenax, uint256 bobEth) =
            (s.tenaxBudget * bobContribution / s.totalContribution, s.ethBudget * bobContribution / s.totalContribution);
        assertEq(weth.balanceOf(alice), aliceEth);
        assertEq(weth.balanceOf(bob), bobEth);
        assertLe(aliceTenax + bobTenax, s.tenaxBudget);
        assertLe(aliceEth + bobEth, s.ethBudget);
        assertEq(tenax.balanceOf(address(rewards)), BUCKET - aliceTenax - bobTenax);

        (uint256 claimableTenax, uint256 claimableEth) = rewards.claimable(0, alice);
        assertEq(claimableTenax + claimableEth, 0);
    }

    function test_claim_locksTenaxForAtLeast52WeeksWithNoEarlyExit() public {
        _registerAndClose();
        (uint256 expected,) = rewards.claimable(0, alice);
        vm.prank(alice);
        rewards.claim(0);

        (uint256 amount, uint256 granted, uint256 end) = escrow.locked(alice);
        assertEq(amount, expected);
        assertEq(granted, expected);
        assertEq(end, (vm.getBlockTimestamp() + 52 weeks) / 1 weeks * 1 weeks);
        assertEq(tenax.balanceOf(alice), 0, "nothing liquid");

        vm.prank(alice);
        vm.expectRevert(VotingEscrow.NoVoluntaryBalance.selector);
        escrow.withdrawEarly();
    }

    function test_claimAsEth_paysNativeEth() public {
        _registerAndClose();
        (, uint256 eth) = rewards.claimable(0, bob);
        uint256 before = bob.balance;
        vm.prank(bob);
        rewards.claimAsEth(0);
        assertEq(bob.balance - before, eth);
        assertEq(weth.balanceOf(bob), 0);
    }

    function test_claim_withAnEmptyBudgetDeliversNothing() public {
        Player[] memory players = new Player[](1);
        players[0] = Player(alice, true, 0, 30);
        _play(players, 0, 29);
        _openRegistration(0);
        _register(alice, 0);
        vm.warp(_closeTime(0));
        rewards.closeSeason(0); // no L1 block has passed and no revenue arrived

        vm.prank(alice);
        rewards.claimAsEth(0);
        (uint256 amount,,) = escrow.locked(alice);
        assertEq(amount, 0);
        assertTrue(rewards.registrationOf(0, alice).claimed);
    }

    function test_RevertWhen_claimingTwice() public {
        _registerAndClose();
        vm.startPrank(alice);
        rewards.claim(0);
        vm.expectRevert(SeasonRewards.AlreadyClaimed.selector);
        rewards.claim(0);
        vm.expectRevert(SeasonRewards.AlreadyClaimed.selector);
        rewards.claimAsEth(0);
        vm.stopPrank();
    }

    function test_RevertWhen_claimingUnregisteredOrOpenSeason() public {
        _playSeasonZero();
        _openRegistration(0);
        _register(alice, 0);
        vm.prank(alice);
        vm.expectRevert(SeasonRewards.SeasonNotClosed.selector);
        rewards.claim(0);
        (uint256 t, uint256 e) = rewards.claimable(0, alice);
        assertEq(t + e, 0);

        vm.warp(_closeTime(0));
        rewards.closeSeason(0);
        vm.prank(carol);
        vm.expectRevert(SeasonRewards.NotRegistered.selector);
        rewards.claim(0);
    }

    function test_claim_blockedByAnExpiredLockUntilWithdrawn() public {
        // Alice has an old voluntary lock that expired before she claims.
        tenax.transfer(alice, 1000e18);
        vm.startPrank(alice);
        tenax.approve(address(escrow), 1000e18);
        escrow.createLock(1000e18, vm.getBlockTimestamp() + 2 weeks);
        vm.stopPrank();

        _registerAndClose();
        vm.startPrank(alice);
        vm.expectRevert(VotingEscrow.LockExpired.selector);
        rewards.claim(0);
        escrow.withdraw();
        rewards.claim(0);
        vm.stopPrank();
    }

    // --- revenue -----------------------------------------------------------------

    function test_depositEth_creditsTheRunningSeason() public {
        vm.warp(GENESIS - 1);
        assertEq(rewards.currentSeason(), 0);
        _deposit(1 ether);
        vm.warp(GENESIS + 30 days - 1);
        _deposit(2 ether);
        vm.warp(GENESIS + 30 days);
        assertEq(rewards.currentSeason(), 1);
        _deposit(4 ether);
        assertEq(rewards.ethReceived(0), 3 ether);
        assertEq(rewards.ethReceived(1), 4 ether);
        assertEq(weth.balanceOf(address(rewards)), 7 ether);
    }

    function test_RevertWhen_depositIsZero() public {
        vm.expectRevert(SeasonRewards.ZeroAmount.selector);
        rewards.depositEth(0);
    }

    function test_RevertWhen_sendingEthDirectly() public {
        vm.deal(address(this), 1 ether);
        (bool ok, bytes memory reason) = address(rewards).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(bytes4(reason), SeasonRewards.UnexpectedEth.selector);
    }

    // --- views and setup ---------------------------------------------------------

    function test_views() public view {
        assertEq(rewards.lastRoundOf(0), 29);
        assertEq(rewards.lastRoundOf(1), 59);
        assertEq(rewards.settlementDelay(), 8 days + 6 hours);
        assertEq(rewards.genesis(), GENESIS);
        assertEq(address(rewards.token()), address(tenax));
    }

    function test_RevertWhen_constructorArgumentsAreInvalid() public {
        IWETH w = IWETH(address(weth));
        vm.expectRevert(SeasonRewards.ZeroAddress.selector);
        new SeasonRewards(IERC20(address(0)), w, escrow, registry, schedule);
        vm.expectRevert(SeasonRewards.ZeroAddress.selector);
        new SeasonRewards(tenax, IWETH(address(0)), escrow, registry, schedule);
        vm.expectRevert(SeasonRewards.ZeroAddress.selector);
        new SeasonRewards(tenax, w, VotingEscrow(address(0)), registry, schedule);
        vm.expectRevert(SeasonRewards.ZeroAddress.selector);
        new SeasonRewards(tenax, w, escrow, ForecastRegistry(address(0)), schedule);
        vm.expectRevert(SeasonRewards.ZeroAddress.selector);
        new SeasonRewards(tenax, w, escrow, registry, EmissionSchedule(address(0)));

        TenaxToken other = new TenaxToken(address(this));
        VotingEscrow otherEscrow = new VotingEscrow(IBurnableERC20(address(other)));
        vm.expectRevert(SeasonRewards.TokenMismatch.selector);
        new SeasonRewards(tenax, w, otherEscrow, registry, schedule);
    }
}
