// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TenaxGovernor} from "../../src/governance/TenaxGovernor.sol";
import {GovernanceTestBase} from "../utils/GovernanceTestBase.sol";
import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";

/// @dev Exposes the governor's internal setters, which governance reaches through proposals.
contract TenaxGovernorHarness is TenaxGovernor {
    constructor(IVotes escrow, TimelockController timelock, address guardian)
        TenaxGovernor(escrow, timelock, guardian)
    {}

    function exposedSetVotingDelay(uint48 value) external {
        _setVotingDelay(value);
    }

    function exposedSetVotingPeriod(uint32 value) external {
        _setVotingPeriod(value);
    }

    function exposedSetProposalThreshold(uint256 value) external {
        _setProposalThreshold(value);
    }

    function exposedUpdateQuorumNumerator(uint256 value) external {
        _updateQuorumNumerator(value);
    }
}

/// @dev Every governor setting accepts exactly the values inside its bounds.
contract GovernorBoundsFuzzTest is GovernanceTestBase {
    TenaxGovernorHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new TenaxGovernorHarness(IVotes(address(escrow)), timelock, safe);
    }

    function _expectBounds(uint256 value, uint256 min, uint256 max) internal {
        if (value < min || value > max) {
            vm.expectRevert(abi.encodeWithSelector(TenaxGovernor.SettingOutOfBounds.selector, value));
        }
    }

    function testFuzz_votingDelay(uint48 value) public {
        _expectBounds(value, 1 hours, 7 days);
        harness.exposedSetVotingDelay(value);
        if (value >= 1 hours && value <= 7 days) assertEq(harness.votingDelay(), value);
    }

    function testFuzz_votingPeriod(uint32 value) public {
        _expectBounds(value, 1 days, 14 days);
        harness.exposedSetVotingPeriod(value);
        if (value >= 1 days && value <= 14 days) assertEq(harness.votingPeriod(), value);
    }

    function testFuzz_proposalThreshold(uint256 value) public {
        value = bound(value, 0, 10_000_000e18);
        _expectBounds(value, 10_000e18, 1_000_000e18);
        harness.exposedSetProposalThreshold(value);
        if (value >= 10_000e18 && value <= 1_000_000e18) assertEq(harness.proposalThreshold(), value);
    }

    function testFuzz_quorumNumerator(uint256 value) public {
        value = bound(value, 0, 100);
        _expectBounds(value, 4, 30);
        harness.exposedUpdateQuorumNumerator(value);
        if (value >= 4 && value <= 30) assertEq(harness.quorumNumerator(), value);
    }
}
