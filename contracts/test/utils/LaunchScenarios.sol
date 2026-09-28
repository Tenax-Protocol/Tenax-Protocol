// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Deploy} from "../../script/Deploy.s.sol";
import {MerkleAirdrop} from "../../src/distribution/MerkleAirdrop.sol";
import {SeasonRewards} from "../../src/distribution/SeasonRewards.sol";
import {VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {LiquidityVault} from "../../src/liquidity/LiquidityVault.sol";
import {RevenueRouter} from "../../src/revenue/RevenueRouter.sol";
import {Treasury} from "../../src/revenue/Treasury.sol";
import {V4Swapper} from "./V4Swapper.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {Test, Vm} from "forge-std/Test.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

/// @dev Runs the deployment script end to end, then launches trading: the launch fee, fee collection into
/// revenue, and a buyback guarded by the hook's real average price. Concrete tests provide the environment:
/// local contracts or a Base mainnet fork.
abstract contract LaunchScenarios is Test {
    using StateLibrary for IPoolManager;

    Deploy internal script;
    Deploy.Config internal config;
    Deploy.Deployment internal d;
    V4Swapper internal swapper;

    address internal safe = makeAddr("safe");
    address internal creator = makeAddr("creator");
    address internal trader = makeAddr("trader");
    address internal keeper = makeAddr("keeper");

    /// @dev Prepares the chain and returns the script configuration.
    function _environment() internal virtual returns (Deploy.Config memory);

    function setUp() public virtual {
        config = _environment();
        script = new Deploy();
        d = script.deploy(config, address(script));
        swapper = new V4Swapper(config.poolManager);
        vm.deal(trader, 10_000 ether);
        vm.prank(trader);
        d.token.approve(address(swapper), type(uint256).max);
    }

    // --- helpers -----------------------------------------------------------------

    function _nextBlock(uint256 seconds_) internal {
        vm.warp(vm.getBlockTimestamp() + seconds_);
        vm.roll(vm.getBlockNumber() + 1);
    }

    function _buy(uint256 eth) internal returns (uint24 fee) {
        vm.recordLogs();
        vm.prank(trader);
        swapper.buy{value: eth}(d.poolKey);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == IPoolManager.Swap.selector) {
                (,,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            }
        }
    }

    function _tick() internal view returns (int24 tick) {
        (, tick,,) = config.poolManager.getSlot0(d.poolKey.toId());
    }

    function _keeper(uint256 taskId, bytes memory data) internal {
        vm.prank(keeper);
        d.treasury.execute(taskId, data);
    }

    function _fundTreasury(uint256 amount) internal {
        vm.deal(address(this), amount);
        config.weth.deposit{value: amount}();
        config.weth.transfer(address(d.treasury), amount);
    }

    // --- scenarios ---------------------------------------------------------------

    function test_deploy_wiresTheWholeProtocol() public view {
        // Allocations: 35 / 20 / 20 / 15 / 10, nothing left with the deployer or the launcher.
        assertEq(d.token.balanceOf(address(d.seasonRewards)), 35_000_000e18);
        assertEq(d.token.balanceOf(address(d.treasury)), 20_000_000e18);
        assertEq(d.token.balanceOf(address(d.creatorVesting)), 15_000_000e18);
        assertEq(d.token.balanceOf(address(d.airdrop)), 10_000_000e18);
        assertEq(d.token.balanceOf(address(script)), 0);
        assertEq(d.token.balanceOf(address(d.launcher)), 0);
        assertGt(config.positionManager.getPositionLiquidity(d.positionId), 0);
        assertEq(IERC721(address(config.positionManager)).ownerOf(d.positionId), address(d.vault));
        assertEq(d.vault.tokenId(), d.positionId);

        // The pool exists at the launch price with the hook, and the treasury watches it.
        assertTrue(d.hook.launched());
        assertEq(_tick(), 138_120);
        assertEq(address(d.treasury.poolManager()), address(config.poolManager));
        assertEq(address(d.treasury.priceObserver()), address(d.hook));
        assertEq(d.treasury.taskCount(), 8);
        assertTrue(d.escrow.isDistributor(address(d.seasonRewards)));
        assertTrue(d.escrow.isDistributor(address(d.airdrop)));
        assertTrue(d.escrow.isDistributor(address(d.treasury)));
        assertEq(d.airdrop.claimDeadline(), vm.getBlockTimestamp() + 90 days);
        assertEq(d.creatorVesting.start(), vm.getBlockTimestamp() + 365 days);
        assertEq(d.creatorVesting.owner(), creator);

        // Governance: the timelock governs every parameter contract and nobody else holds power over it.
        assertEq(d.registry.governance(), address(d.timelock));
        assertEq(d.router.governance(), address(d.timelock));
        assertEq(d.treasury.governance(), address(d.timelock));
        assertEq(d.governor.proposalGuardian(), safe);
        assertTrue(d.timelock.hasRole(d.timelock.PROPOSER_ROLE(), address(d.governor)));
        assertTrue(d.timelock.hasRole(d.timelock.CANCELLER_ROLE(), safe));
        assertFalse(d.timelock.hasRole(d.timelock.DEFAULT_ADMIN_ROLE(), address(script)));
    }

    function test_deploy_keeperTasksExpectTheirExactCalldata() public view {
        ForecastRegistry.PriceHints memory hints;
        bytes[8] memory calls = [
            abi.encodeCall(ForecastRegistry.resolveRound, (0, 0, hints)),
            abi.encodeCall(ForecastRegistry.voidExpiredRound, (0, 0)),
            abi.encodeCall(ForecastRegistry.finalizeRound, (0, 0)),
            abi.encodeCall(SeasonRewards.register, (address(0), 0)),
            abi.encodeCall(SeasonRewards.closeSeason, (0)),
            abi.encodeCall(LiquidityVault.collectFees, ()),
            abi.encodeCall(Treasury.buyback, ()),
            abi.encodeCall(RevenueRouter.distribute, ())
        ];
        for (uint256 i; i < calls.length; ++i) {
            Treasury.Task memory task = d.treasury.task(i);
            assertEq(task.dataLength, calls[i].length);
            assertEq(task.selector, bytes4(calls[i]));
        }
    }

    function test_deploy_leavesTheDeployerNoPower() public {
        address[] memory none = new address[](0);
        Treasury.Task[] memory noTasks = new Treasury.Task[](0);
        vm.startPrank(address(script));
        vm.expectRevert(VotingEscrow.DistributorsAlreadyInitialized.selector);
        d.escrow.initializeDistributors(none);
        vm.expectRevert(Treasury.AlreadyInitialized.selector);
        d.treasury.initialize(d.seasonRewards, noTasks);
        vm.expectRevert(Treasury.AlreadyInitialized.selector);
        d.treasury.initializeMarket(config.poolManager, d.poolKey, d.hook);
        vm.expectRevert(LiquidityVault.AlreadyInitialized.selector);
        d.vault.initialize(d.positionId);
        vm.expectRevert(MerkleAirdrop.AlreadyOpened.selector);
        d.airdrop.open();
        vm.expectRevert();
        d.launcher.launch(d.poolKey, 138_120, address(d.vault));
        vm.stopPrank();
    }

    function test_launch_feeDecaysAndFeesReachRevenue() public {
        vm.roll(vm.getBlockNumber() - 1);
        _nextBlock(2); // same block as the launch
        assertEq(_buy(1 ether), uint24(200_000), "20% in the launch block");
        _nextBlock(2);
        assertEq(_buy(1 ether), uint24(199_344), "one block later: 200,000 - 197,000 / 300");
        vm.roll(d.hook.launchBlock() + 300);
        _nextBlock(2);
        assertEq(_buy(1 ether), uint24(3000), "0.3% from block 300 on");

        _keeper(5, abi.encodeCall(LiquidityVault.collectFees, ()));
        uint256 eth = d.vault.totalEthCollected();
        assertApproxEqRel(eth, 0.2 ether + 0.199_34 ether + 0.003 ether, 0.001e18);
        uint256 season = d.seasonRewards.currentSeason();
        assertEq(d.seasonRewards.ethReceived(season), eth * 4000 / 10_000);
        assertEq(config.weth.balanceOf(address(d.feeDistributor)), eth * 4000 / 10_000);
        assertGe(config.weth.balanceOf(address(d.treasury)) + config.weth.balanceOf(keeper), eth / 5);
    }

    function test_buyback_isGuardedByTheHookAverage() public {
        vm.roll(d.hook.launchBlock() + 300);
        _nextBlock(600);
        _buy(2 ether);
        _nextBlock(1800);
        _fundTreasury(1 ether);

        uint256 supply = d.token.totalSupply();
        _keeper(6, abi.encodeCall(Treasury.buyback, ()));
        assertEq(d.treasury.totalBuybackEth(), 0.05 ether);
        assertEq(supply - d.token.totalSupply(), d.treasury.totalBuybackBurned());
        assertGt(d.treasury.totalBuybackBurned(), 0);

        // A day later someone pushes the price in the block before the buyback: the average barely moves.
        _nextBlock(1 days);
        _buy(200 ether);
        _nextBlock(2);
        int24 tick = _tick();
        int24 mean = d.hook.meanTick(1800);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Treasury.PriceDeviation.selector, tick, mean));
        d.treasury.execute(6, abi.encodeCall(Treasury.buyback, ()));
    }
}
