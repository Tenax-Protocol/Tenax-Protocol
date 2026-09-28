// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWETH} from "../../src/interfaces/IWETH.sol";
import {LiquidityScenarios} from "../utils/LiquidityScenarios.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev Runs the fee collection and buyback scenarios against the live Uniswap v4 deployment and WETH on Base
/// mainnet: a fresh ETH / TENAX pool is created on the real pool manager and its position minted through the real
/// position manager. Skipped unless BASE_RPC_URL is set. Addresses come from Uniswap's deployment list and can be
/// overridden with POOL_MANAGER, POSITION_MANAGER and WETH.
contract LiquidityForkTest is LiquidityScenarios {
    function setUp() public override {
        if (bytes(vm.envOr("BASE_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        super.setUp();
    }

    function _uniswap() internal override returns (IPoolManager, IPositionManager, IWETH) {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        return (
            IPoolManager(vm.envOr("POOL_MANAGER", address(0x498581fF718922c3f8e6A244956aF099B2652b2b))),
            IPositionManager(vm.envOr("POSITION_MANAGER", address(0x7C5f5A4bBd8fD63184577525326123B519429bDc))),
            IWETH(vm.envOr("WETH", address(0x4200000000000000000000000000000000000006)))
        );
    }
}
