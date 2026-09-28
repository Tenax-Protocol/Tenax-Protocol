// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Receivers of revenue that pull WETH deposits from the router: season rewards and the fee distributor.
interface IEthDepositor {
    function depositEth(uint256 amount) external;
}
