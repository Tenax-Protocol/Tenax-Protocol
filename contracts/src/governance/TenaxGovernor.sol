// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Governor} from "@openzeppelin/contracts/governance/Governor.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {GovernorCountingSimple} from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import {GovernorProposalGuardian} from "@openzeppelin/contracts/governance/extensions/GovernorProposalGuardian.sol";
import {GovernorSettings} from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import {GovernorTimelockControl} from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import {GovernorVotes} from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @title TenaxGovernor
/// @notice Governance of the protocol's bounded parameters, voted with veTENAX (whitepaper section 8).
/// @dev OpenZeppelin's Governor reading voting power from the vote escrow, whose clock is the block timestamp, so
/// every delay and period below is in seconds. Proposals execute through the timelock. A guardian (the Safe) can
/// cancel any proposal but cannot propose; governance can replace or remove it.
///
/// The governor's own settings are bounded like every other protocol parameter: voting delay from 1 hour to 7 days,
/// voting period from 1 to 14 days, proposal threshold from 10,000 to 1,000,000 veTENAX and quorum from 4% to 30%
/// of the veTENAX supply at the snapshot.
contract TenaxGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl,
    GovernorProposalGuardian
{
    uint48 public constant INITIAL_VOTING_DELAY = 1 days;
    uint32 public constant INITIAL_VOTING_PERIOD = 5 days;
    uint256 public constant INITIAL_PROPOSAL_THRESHOLD = 100_000e18;
    uint256 public constant INITIAL_QUORUM_PERCENT = 10;

    uint256 public constant MIN_VOTING_DELAY = 1 hours;
    uint256 public constant MAX_VOTING_DELAY = 7 days;
    uint256 public constant MIN_VOTING_PERIOD = 1 days;
    uint256 public constant MAX_VOTING_PERIOD = 14 days;
    uint256 public constant MIN_PROPOSAL_THRESHOLD = 10_000e18;
    uint256 public constant MAX_PROPOSAL_THRESHOLD = 1_000_000e18;
    uint256 public constant MIN_QUORUM_PERCENT = 4;
    uint256 public constant MAX_QUORUM_PERCENT = 30;

    error SettingOutOfBounds(uint256 value);

    /// @param escrow Vote escrow providing veTENAX voting power.
    /// @param timelock Timelock that executes proposals.
    /// @param guardian Safe allowed to cancel proposals.
    constructor(IVotes escrow, TimelockController timelock, address guardian)
        Governor("Tenax Governor")
        GovernorSettings(INITIAL_VOTING_DELAY, INITIAL_VOTING_PERIOD, INITIAL_PROPOSAL_THRESHOLD)
        GovernorVotes(escrow)
        GovernorVotesQuorumFraction(INITIAL_QUORUM_PERCENT)
        GovernorTimelockControl(timelock)
    {
        _setProposalGuardian(guardian);
    }

    // --- bounded settings --------------------------------------------------------

    function _setVotingDelay(uint48 newVotingDelay) internal override {
        _checkBounds(newVotingDelay, MIN_VOTING_DELAY, MAX_VOTING_DELAY);
        super._setVotingDelay(newVotingDelay);
    }

    function _setVotingPeriod(uint32 newVotingPeriod) internal override {
        _checkBounds(newVotingPeriod, MIN_VOTING_PERIOD, MAX_VOTING_PERIOD);
        super._setVotingPeriod(newVotingPeriod);
    }

    function _setProposalThreshold(uint256 newProposalThreshold) internal override {
        _checkBounds(newProposalThreshold, MIN_PROPOSAL_THRESHOLD, MAX_PROPOSAL_THRESHOLD);
        super._setProposalThreshold(newProposalThreshold);
    }

    function _updateQuorumNumerator(uint256 newQuorumNumerator) internal override {
        _checkBounds(newQuorumNumerator, MIN_QUORUM_PERCENT, MAX_QUORUM_PERCENT);
        super._updateQuorumNumerator(newQuorumNumerator);
    }

    function _checkBounds(uint256 value, uint256 min, uint256 max) private pure {
        if (value < min || value > max) revert SettingOutOfBounds(value);
    }

    // --- required overrides ------------------------------------------------------

    function votingDelay() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingDelay();
    }

    function votingPeriod() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.votingPeriod();
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }

    function _validateCancel(uint256 proposalId, address caller)
        internal
        view
        override(Governor, GovernorProposalGuardian)
        returns (bool)
    {
        return super._validateCancel(proposalId, caller);
    }
}
