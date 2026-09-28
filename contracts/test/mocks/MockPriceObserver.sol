// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPriceObserver} from "../../src/interfaces/IPriceObserver.sol";

/// @dev Stand-in for the launch hook's average price, set by the test.
contract MockPriceObserver is IPriceObserver {
    int24 public mean;

    function setMeanTick(int24 tick) external {
        mean = tick;
    }

    function meanTick(uint32) external view returns (int24) {
        return mean;
    }
}
