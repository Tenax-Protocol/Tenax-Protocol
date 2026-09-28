// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {TenaxGovernor} from "../../src/governance/TenaxGovernor.sol";
import {TenaxTimelock} from "../../src/governance/TenaxTimelock.sol";
import {RevenueRouter} from "../../src/revenue/RevenueRouter.sol";
import {Treasury} from "../../src/revenue/Treasury.sol";
import {GovernanceTestBase} from "../utils/GovernanceTestBase.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorProposalGuardian} from "@openzeppelin/contracts/governance/extensions/GovernorProposalGuardian.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

contract GovernanceTest is GovernanceTestBase {
    uint8 internal constant AGAINST = 0;
    uint8 internal constant FOR = 1;
    uint8 internal constant ABSTAIN = 2;

    // --- setup -------------------------------------------------------------------

    function test_setup_matchesTheWhitepaper() public view {
        assertEq(governor.votingDelay(), 1 days);
        assertEq(governor.votingPeriod(), 5 days);
        assertEq(governor.proposalThreshold(), 100_000e18);
        assertEq(governor.quorumNumerator(), 10);
        assertEq(timelock.getMinDelay(), 2 days);
        assertEq(governor.name(), "Tenax Governor");
        assertEq(address(governor.token()), address(escrow));
        assertEq(address(governor.timelock()), address(timelock));
        assertEq(governor.proposalGuardian(), safe);
        assertEq(governor.CLOCK_MODE(), "mode=timestamp");
        assertEq(governor.clock(), vm.getBlockTimestamp());
    }

    function test_setup_rolesLeaveNoPrivilegedDeployer() public view {
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), safe));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), safe), "the Safe cannot propose");
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)), "anyone executes");
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)), "self-administered");
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(this)), "deployer renounced");
        assertEq(router.governance(), address(timelock));
        assertEq(treasury.governance(), address(timelock));
        assertEq(registry.governance(), address(timelock));
    }

    // --- full flow ---------------------------------------------------------------

    function test_fullProposalFlow_changesBoundedParameters() public {
        Proposal memory p;
        p.targets = new address[](3);
        p.targets[0] = address(router);
        p.targets[1] = address(treasury);
        p.targets[2] = address(registry);
        p.values = new uint256[](3);
        p.calldatas = new bytes[](3);
        p.calldatas[0] = abi.encodeCall(RevenueRouter.setShares, (4500, 3500, 2000));
        p.calldatas[1] = abi.encodeCall(Treasury.setBuybackCap, (0.1 ether));
        p.calldatas[2] = abi.encodeCall(ForecastRegistry.setRevealWindow, (72 hours));
        p.description = "Adjust the revenue split, the buyback cap and the reveal window";

        uint256 id = _propose(carol, p); // 150,000 veTENAX: above the 100,000 threshold
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Pending));
        assertEq(governor.proposalSnapshot(id), vm.getBlockTimestamp() + 1 days);

        _toVoting(id);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Active));
        _vote(alice, id, FOR);
        _vote(bob, id, AGAINST);
        _vote(carol, id, ABSTAIN);
        (uint256 against, uint256 inFavor, uint256 abstain) = governor.proposalVotes(id);
        assertGt(inFavor, against + abstain);

        _toEnd(id);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Succeeded));
        _queue(p);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Queued));

        vm.warp(governor.proposalEta(id) - 1);
        vm.expectRevert();
        _execute(p);

        vm.warp(governor.proposalEta(id));
        _execute(p);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Executed));
        assertEq(router.forecastersBps(), 4500);
        assertEq(router.holdersBps(), 3500);
        assertEq(treasury.buybackCap(), 0.1 ether);
        assertEq(registry.revealWindow(), 72 hours);
    }

    function test_RevertWhen_proposerIsBelowTheThreshold() public {
        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "cap");
        uint256 votes = escrow.getPastVotes(dave, vm.getBlockTimestamp() - 1);
        vm.prank(dave);
        vm.expectRevert(
            abi.encodeWithSelector(IGovernor.GovernorInsufficientProposerVotes.selector, dave, votes, 100_000e18)
        );
        governor.propose(p.targets, p.values, p.calldatas, p.description);
    }

    function test_proposal_defeatedWithoutQuorum() public {
        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "cap");
        uint256 id = _propose(carol, p);
        _toVoting(id);
        _vote(carol, id, FOR); // 150,000 against a quorum of 10% of about 2.7M
        _vote(dave, id, FOR);
        uint256 snapshot = governor.proposalSnapshot(id);
        (, uint256 inFavor,) = governor.proposalVotes(id);
        assertEq(inFavor, escrow.getPastVotes(carol, snapshot) + escrow.getPastVotes(dave, snapshot));
        assertLt(inFavor, governor.quorum(snapshot));
        _toEnd(id);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_proposal_defeatedWhenAgainstWins() public {
        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "cap");
        uint256 id = _propose(bob, p);
        _toVoting(id);
        _vote(bob, id, FOR);
        _vote(alice, id, AGAINST);
        _toEnd(id);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Defeated));
    }

    function test_votes_countAtTheSnapshotOnly() public {
        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "cap");
        uint256 id = _propose(alice, p);
        _toVoting(id);
        address late = makeAddr("late");
        _lock(late, 5_000_000e18); // after the snapshot: no weight in this proposal
        _vote(late, id, AGAINST);
        _vote(alice, id, FOR);
        (uint256 against,,) = governor.proposalVotes(id);
        assertEq(against, 0);
        _toEnd(id);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Succeeded));
    }

    function test_anyoneExecutes_butNobodyBypassesTheTimelock() public {
        vm.expectRevert(RevenueRouter.NotGovernance.selector);
        router.setShares(4500, 3500, 2000);

        bytes memory call = abi.encodeCall(RevenueRouter.setShares, (4500, 3500, 2000));
        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(safe);
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, safe, proposerRole)
        );
        timelock.schedule(address(router), 0, call, bytes32(0), bytes32(0), 2 days);
    }

    // --- bounds ------------------------------------------------------------------

    function test_outOfBoundsParameters_neverApply() public {
        Proposal memory p =
            _single(address(router), abi.encodeCall(RevenueRouter.setShares, (6000, 2000, 2000)), "too much");
        uint256 id = _passAndQueue(p);
        vm.expectRevert(RevenueRouter.InvalidShares.selector);
        _execute(p);
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Queued));
        assertEq(router.forecastersBps(), 4000);
    }

    function test_governorSettings_changeOnlyWithinBounds() public {
        Proposal memory p = _single(address(governor), abi.encodeCall(governor.setVotingPeriod, (15 days)), "too long");
        _passAndQueue(p);
        vm.expectRevert(abi.encodeWithSelector(TenaxGovernor.SettingOutOfBounds.selector, 15 days));
        _execute(p);

        p.targets = new address[](4);
        p.values = new uint256[](4);
        p.calldatas = new bytes[](4);
        for (uint256 i; i < 4; ++i) {
            p.targets[i] = address(governor);
        }
        p.calldatas[0] = abi.encodeCall(governor.setVotingDelay, (2 hours));
        p.calldatas[1] = abi.encodeCall(governor.setVotingPeriod, (7 days));
        p.calldatas[2] = abi.encodeCall(governor.setProposalThreshold, (50_000e18));
        p.calldatas[3] = abi.encodeCall(governor.updateQuorumNumerator, (15));
        p.description = "retune";
        _passAndQueue(p);
        _execute(p);
        assertEq(governor.votingDelay(), 2 hours);
        assertEq(governor.votingPeriod(), 7 days);
        assertEq(governor.proposalThreshold(), 50_000e18);
        assertEq(governor.quorumNumerator(), 15);
    }

    function test_timelockDelay_changesOnlyWithinBoundsAndThroughItself() public {
        vm.expectRevert(abi.encodeWithSelector(TimelockController.TimelockUnauthorizedCaller.selector, address(this)));
        timelock.updateDelay(3 days);

        Proposal memory p = _single(address(timelock), abi.encodeCall(timelock.updateDelay, (15 days)), "too long");
        _passAndQueue(p);
        vm.expectRevert(abi.encodeWithSelector(TenaxTimelock.DelayOutOfBounds.selector, 15 days));
        _execute(p);

        p = _single(address(timelock), abi.encodeCall(timelock.updateDelay, (3 days)), "longer");
        _passAndQueue(p);
        _execute(p);
        assertEq(timelock.getMinDelay(), 3 days);
    }

    function test_RevertWhen_timelockDelayIsOutOfBoundsAtDeployment() public {
        address[] memory none = new address[](0);
        vm.expectRevert(abi.encodeWithSelector(TenaxTimelock.DelayOutOfBounds.selector, 12 hours));
        new TenaxTimelock(12 hours, none, none, address(0));
        vm.expectRevert(abi.encodeWithSelector(TenaxTimelock.DelayOutOfBounds.selector, 15 days));
        new TenaxTimelock(15 days, none, none, address(0));
    }

    // --- guardian ----------------------------------------------------------------

    function test_guardian_cancelsPendingAndQueuedProposals() public {
        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "a");
        uint256 id = _propose(alice, p);
        vm.prank(safe);
        governor.cancel(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Canceled));

        p.description = "b";
        id = _passAndQueue(p);
        bytes32 operation = timelock.hashOperationBatch(
            p.targets, p.values, p.calldatas, 0, bytes20(address(governor)) ^ keccak256("b")
        );
        assertTrue(timelock.isOperationReady(operation));
        vm.prank(safe);
        governor.cancel(p.targets, p.values, p.calldatas, keccak256("b"));
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Canceled));
        assertFalse(timelock.isOperation(operation), "timelock operation removed");
        vm.expectRevert();
        _execute(p);
    }

    /// @dev Besides the guardian, only the proposer can cancel, and only while the proposal is pending.
    function test_RevertWhen_othersCancelOrTheProposerCancelsAfterVotingOpens() public {
        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "a");
        uint256 id = _propose(alice, p);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, bob));
        governor.cancel(p.targets, p.values, p.calldatas, keccak256("a"));

        _toVoting(id);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, alice));
        governor.cancel(p.targets, p.values, p.calldatas, keccak256("a"));

        vm.prank(safe);
        governor.cancel(p.targets, p.values, p.calldatas, keccak256("a"));
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_proposer_cancelsWhilePending() public {
        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "a");
        uint256 id = _propose(alice, p);
        vm.prank(alice);
        governor.cancel(p.targets, p.values, p.calldatas, keccak256("a"));
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    function test_governance_canRemoveTheGuardian() public {
        Proposal memory p;
        p.targets = new address[](2);
        p.targets[0] = address(governor);
        p.targets[1] = address(timelock);
        p.values = new uint256[](2);
        p.calldatas = new bytes[](2);
        p.calldatas[0] = abi.encodeCall(GovernorProposalGuardian.setProposalGuardian, (address(0)));
        p.calldatas[1] = abi.encodeCall(IAccessControl.revokeRole, (timelock.CANCELLER_ROLE(), safe));
        p.description = "retire the guardian";
        _passAndQueue(p);
        _execute(p);
        assertEq(governor.proposalGuardian(), address(0));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), safe));

        // Without a guardian, the Safe cannot cancel, and proposers can cancel their own proposals at any point.
        Proposal memory q = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "c");
        uint256 id = _propose(bob, q);
        _toVoting(id);
        vm.prank(safe);
        vm.expectRevert(abi.encodeWithSelector(IGovernor.GovernorUnableToCancel.selector, id, safe));
        governor.cancel(q.targets, q.values, q.calldatas, keccak256("c"));
        vm.prank(bob); // even while voting is open
        governor.cancel(q.targets, q.values, q.calldatas, keccak256("c"));
        assertEq(uint8(_state(id)), uint8(IGovernor.ProposalState.Canceled));
    }

    // --- fuzz --------------------------------------------------------------------

    /// @dev A proposal succeeds exactly when votes in favor beat votes against and, with abstentions, reach 10% of
    /// the veTENAX supply at the snapshot.
    function testFuzz_outcomeFollowsQuorumAndMajority(uint256 inFavor, uint256 against, uint256 abstain) public {
        address[3] memory voters = [makeAddr("yes"), makeAddr("no"), makeAddr("abstain")];
        uint256[3] memory amounts =
            [bound(inFavor, 0, 5_000_000e18), bound(against, 0, 5_000_000e18), bound(abstain, 0, 5_000_000e18)];
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] != 0) _lock(voters[i], amounts[i]);
        }
        vm.warp(vm.getBlockTimestamp() + 1);

        Proposal memory p = _single(address(treasury), abi.encodeCall(Treasury.setBuybackCap, (0.1 ether)), "fuzz");
        uint256 id = _propose(carol, p);
        _toVoting(id);
        for (uint256 i; i < 3; ++i) {
            if (amounts[i] != 0) _vote(voters[i], id, i == 0 ? FOR : i == 1 ? AGAINST : ABSTAIN);
        }
        _toEnd(id);

        uint256 snapshot = governor.proposalSnapshot(id);
        uint256 yes = IVotes(address(escrow)).getPastVotes(voters[0], snapshot);
        uint256 no = IVotes(address(escrow)).getPastVotes(voters[1], snapshot);
        uint256 abs = IVotes(address(escrow)).getPastVotes(voters[2], snapshot);
        bool succeeds = yes > no && yes + abs >= governor.quorum(snapshot);
        IGovernor.ProposalState expected =
            succeeds ? IGovernor.ProposalState.Succeeded : IGovernor.ProposalState.Defeated;
        assertEq(uint8(_state(id)), uint8(expected));
    }
}
