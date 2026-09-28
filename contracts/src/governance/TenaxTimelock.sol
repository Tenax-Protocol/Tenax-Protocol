// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TimelockController} from "@openzeppelin/contracts/governance/TimelockController.sol";

/// @title TenaxTimelock
/// @notice Executes the governor's proposals after a delay (whitepaper section 8).
/// @dev OpenZeppelin's TimelockController with its delay bounded to 1 to 14 days, both at deployment and when
/// governance changes it. Roles are set by the deployment: the governor proposes and cancels, the guardian Safe
/// cancels, anyone executes, and the deployer renounces its admin role, leaving the timelock as its own admin.
contract TenaxTimelock is TimelockController {
    uint256 public constant MIN_DELAY_LIMIT = 1 days;
    uint256 public constant MAX_DELAY_LIMIT = 14 days;

    error DelayOutOfBounds(uint256 delay);

    constructor(uint256 minDelay, address[] memory proposers, address[] memory executors, address admin)
        TimelockController(minDelay, proposers, executors, admin)
    {
        _checkDelay(minDelay);
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
