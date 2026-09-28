// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "../../script/Deploy.s.sol";
import {IAggregatorV3} from "../../src/forecast/OracleAdapter.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockL1Block} from "../mocks/MockL1Block.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {LaunchScenarios} from "../utils/LaunchScenarios.sol";

import {PoolManager} from "@uniswap/v4-core/src/PoolManager.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev The deployment script and launch against locally compiled Uniswap, mock feeds and mock predeploys.
contract LaunchTest is LaunchScenarios {
    /// @dev Runtime code of the deterministic deployment proxy that forge scripts use for CREATE2.
    bytes internal constant CREATE2_FACTORY_CODE =
        hex"7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffe03601600081602082378035828234f58015156039578182fd5b8082525050506014600cf3";

    function _environment() internal override returns (Deploy.Config memory c) {
        vm.warp(1_800_000_000);
        vm.roll(5_000_000);
        vm.etch(CREATE2_FACTORY, CREATE2_FACTORY_CODE);
        new MockL1Block().install(vm, 21_000_000);

        IPoolManager manager = new PoolManager(address(this));
        IWETH weth = IWETH(address(new MockWETH()));
        bytes memory args = abi.encode(address(manager), address(0xdead), 100_000, address(0), address(weth));
        c.positionManager = IPositionManager(deployCode("PositionManager.sol:PositionManager", args));
        c.poolManager = manager;
        c.weth = weth;

        MockAggregator sequencer = new MockAggregator(0);
        sequencer.push(0, block.timestamp - 30 days, block.timestamp - 30 days);
        c.btcFeed = IAggregatorV3(address(new MockAggregator(8)));
        c.ethFeed = IAggregatorV3(address(new MockAggregator(8)));
        c.sequencerFeed = IAggregatorV3(address(sequencer));
        c.staleness = 3960;
        c.sequencerGrace = 1 hours;

        c.safe = safe;
        c.creator = creator;
        c.genesis = (block.timestamp / 1 days + 1) * 1 days;
        c.initialThresholds = new uint256[](2);
        c.initialThresholds[0] = 0.02e18;
        c.initialThresholds[1] = 0.028e18;
        c.initialBaseRates = new uint256[](2);
        c.initialBaseRates[0] = 0.36e18;
        c.initialBaseRates[1] = 0.36e18;
        c.airdropRoot = keccak256("airdrop root");
    }
}
