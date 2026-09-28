// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "../../script/Deploy.s.sol";
import {IAggregatorV3} from "../../src/forecast/OracleAdapter.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {LaunchScenarios} from "../utils/LaunchScenarios.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

/// @dev The deployment script and launch on a Base mainnet fork, against the live Uniswap v4 pool manager and
/// position manager, WETH, Chainlink feeds, the L1Block predeploy and the standard CREATE2 factory. Skipped
/// unless BASE_RPC_URL is set.
contract LaunchForkTest is LaunchScenarios {
    function setUp() public override {
        if (bytes(vm.envOr("BASE_RPC_URL", string(""))).length == 0) {
            vm.skip(true);
            return;
        }
        super.setUp();
    }

    function _environment() internal override returns (Deploy.Config memory c) {
        vm.createSelectFork(vm.envString("BASE_RPC_URL"));
        c.weth = IWETH(0x4200000000000000000000000000000000000006);
        c.poolManager = IPoolManager(0x498581fF718922c3f8e6A244956aF099B2652b2b);
        c.positionManager = IPositionManager(0x7C5f5A4bBd8fD63184577525326123B519429bDc);
        c.btcFeed = IAggregatorV3(0x32F587986D3fb47601157c19615d568BeD0BCabc);
        c.ethFeed = IAggregatorV3(0xa4250cE1aA15Ff4cb5E5a8655293b65694e436Ed);
        c.sequencerFeed = IAggregatorV3(0xBCF85224fc0756B9Fa45aA7892530B47e10b6433);
        c.staleness = 1320;
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
