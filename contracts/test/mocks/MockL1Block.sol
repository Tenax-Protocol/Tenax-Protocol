// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IL1Block} from "../../src/distribution/EmissionSchedule.sol";
import {Vm} from "forge-std/Vm.sol";

/// @dev Stand-in for the OP Stack L1Block predeploy, etched at its official address by `install`.
contract MockL1Block is IL1Block {
    address internal constant PREDEPLOY = 0x4200000000000000000000000000000000000015;

    uint64 public number;

    function setNumber(uint64 value) external {
        number = value;
    }

    /// @dev Places this mock at the predeploy address and returns a handle to it.
    function install(Vm vm, uint64 initialNumber) external returns (MockL1Block l1) {
        vm.etch(PREDEPLOY, address(this).code);
        l1 = MockL1Block(PREDEPLOY);
        l1.setNumber(initialNumber);
    }
}
