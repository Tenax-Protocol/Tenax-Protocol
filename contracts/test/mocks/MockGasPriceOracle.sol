// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";

/// @dev Stand-in for the OP Stack GasPriceOracle predeploy, etched at its official address by `install`.
contract MockGasPriceOracle {
    address internal constant PREDEPLOY = 0x420000000000000000000000000000000000000F;

    uint256 public l1Fee;

    function setL1Fee(uint256 fee) external {
        l1Fee = fee;
    }

    function getL1FeeUpperBound(uint256 unsignedTxSize) external view returns (uint256) {
        return unsignedTxSize == 0 ? 0 : l1Fee;
    }

    function install(Vm vm, uint256 fee) external returns (MockGasPriceOracle oracle) {
        vm.etch(PREDEPLOY, address(this).code);
        oracle = MockGasPriceOracle(PREDEPLOY);
        oracle.setL1Fee(fee);
    }
}
