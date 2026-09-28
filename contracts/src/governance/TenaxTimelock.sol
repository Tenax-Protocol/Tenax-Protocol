// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title TenaxTimelock
/// @notice Executes the governor's proposals after a delay (whitepaper section 8).
/// @dev OpenZeppelin's TimelockController with its delay bounded to 1 to 14 days, both at deployment and when
/// governance changes it. Roles are set by the deployment: the governor proposes and cancels, the guardian Safe
/// cancels, anyone executes, and the deployer renounces its admin role, leaving the timelock as its own admin.
///
/// The guardian's power to cancel expires on its own 104 weeks after deployment, whatever roles it still holds,
/// because the guardian could otherwise cancel the very operation that removes it.
contract TenaxTimelock is TimelockController {
    uint256 public constant MIN_DELAY_LIMIT = 1 days;
    uint256 public constant MAX_DELAY_LIMIT = 14 days;
    uint256 public constant GUARDIAN_TERM = 104 weeks;

    /// @notice The Safe that can cancel queued operations until `guardianExpiry`.
    address public immutable guardian;
    uint256 public immutable guardianExpiry;

    error DelayOutOfBounds(uint256 delay);
    error GuardianExpired();
    error ZeroAddress();

    constructor(
        uint256 minDelay,
        address[] memory proposers,
        address[] memory executors,
        address admin,
        address guardian_
    ) TimelockController(minDelay, proposers, executors, admin) {
        _checkDelay(minDelay);
        if (guardian_ == address(0)) revert ZeroAddress();
        guardian = guardian_;
        guardianExpiry = block.timestamp + GUARDIAN_TERM;
    }

    /// @inheritdoc TimelockController
    function cancel(bytes32 id) public override {
        if (msg.sender == guardian && block.timestamp >= guardianExpiry) revert GuardianExpired();
        super.cancel(id);
    }

    /// @inheritdoc TimelockController
    function updateDelay(uint256 newDelay) public override {
        _checkDelay(newDelay);
        super.updateDelay(newDelay);
    }

    function _checkDelay(uint256 delay) private pure {
        if (delay < MIN_DELAY_LIMIT || delay > MAX_DELAY_LIMIT) revert DelayOutOfBounds(delay);
    }
}
