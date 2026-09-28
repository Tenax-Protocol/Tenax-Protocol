// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

// Brings Uniswap's PositionManager into the build so tests can deploy it from its artifact with `vm.getCode`.
// It is compiled apart, through the IR pipeline (see foundry.toml), and never imported by a test directly.
import {PositionManager} from "@uniswap/v4-periphery/src/PositionManager.sol";
