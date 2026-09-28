// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @dev Receiver that pulls WETH through `depositEth`, like season rewards and the fee distributor.
contract MockEthDepositor {
    IERC20 public immutable weth;
    uint256 public received;

    constructor(IERC20 weth_) {
        weth = weth_;
    }

    function depositEth(uint256 amount) external {
        received += amount;
        weth.transferFrom(msg.sender, address(this), amount);
    }
}
