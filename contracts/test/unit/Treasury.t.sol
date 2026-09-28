// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {EmissionSchedule} from "../../src/distribution/EmissionSchedule.sol";
import {SeasonRewards} from "../../src/distribution/SeasonRewards.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {Treasury} from "../../src/revenue/Treasury.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockGasPriceOracle} from "../mocks/MockGasPriceOracle.sol";
import {MockL1Block} from "../mocks/MockL1Block.sol";
import {MockSeasonRegistry} from "../mocks/MockSeasonRegistry.sol";
import {MockTaskTarget} from "../mocks/MockTaskTarget.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {Test, Vm} from "forge-std/Test.sol";

contract TreasuryTest is Test {
    uint256 internal constant GENESIS = 1_799_971_200;
    uint256 internal constant L1_START = 21_000_000;
    uint256 internal constant RESERVE = 20_000_000e18;
    uint256 internal constant SEASON = 30 days;

    uint256 internal constant WORK = 0;
    uint256 internal constant DAILY_WORK = 1;
    uint256 internal constant FAIL = 2;
    uint256 internal constant CLOSE = 3;
    uint256 internal constant REGISTER = 4;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    MockWETH internal weth;
    MockSeasonRegistry internal registry;
    MockGasPriceOracle internal gasOracle;
    MockL1Block internal l1;
    SeasonRewards internal rewards;
    Treasury internal treasury;
    MockTaskTarget internal target;

    address internal governance = makeAddr("governance");
    address internal keeper = makeAddr("keeper");
    address internal alice = makeAddr("alice");

    function setUp() public {
        vm.warp(GENESIS);
        l1 = new MockL1Block().install(vm, uint64(L1_START));
        gasOracle = new MockGasPriceOracle().install(vm, 0);
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        weth = new MockWETH();
        registry = new MockSeasonRegistry(GENESIS);
        registry.setNextRoundToResolve(type(uint256).max);
        treasury = new Treasury(IBurnableERC20(address(tenax)), IWETH(address(weth)), escrow, governance);
        rewards = new SeasonRewards(
            tenax,
            IWETH(address(weth)),
            escrow,
            ForecastRegistry(address(registry)),
            new EmissionSchedule(L1_START),
            treasury
        );
        target = new MockTaskTarget();

        treasury.initialize(rewards, _tasks());
        address[] memory distributors = new address[](2);
        distributors[0] = address(rewards);
        distributors[1] = address(treasury);
        escrow.initializeDistributors(distributors);
        tenax.transfer(address(rewards), 35_000_000e18);
        tenax.transfer(address(treasury), RESERVE);

        vm.fee(0.005 gwei);
        vm.txGasPrice(0.006 gwei);
    }

    function _tasks() internal view returns (Treasury.Task[] memory tasks) {
        tasks = new Treasury.Task[](5);
        tasks[WORK] = Treasury.Task(address(target), MockTaskTarget.work.selector, 0, 36);
        tasks[DAILY_WORK] = Treasury.Task(address(target), MockTaskTarget.work.selector, 1 days, 36);
        tasks[FAIL] = Treasury.Task(address(target), MockTaskTarget.fail.selector, 0, 4);
        tasks[CLOSE] = Treasury.Task(address(rewards), SeasonRewards.closeSeason.selector, 0, 36);
        tasks[REGISTER] = Treasury.Task(address(rewards), SeasonRewards.register.selector, 0, 68);
    }

    function _fundWeth(uint256 amount) internal {
        vm.deal(address(this), amount);
        weth.deposit{value: amount}();
        weth.transfer(address(treasury), amount);
    }

    /// @dev Runs a task as the keeper and returns the measured gas and the payments from the emitted events.
    function _execute(uint256 taskId, bytes memory data)
        internal
        returns (uint256 gasUsed, uint256 ethPaid, uint256 tenaxPaid)
    {
        vm.recordLogs();
        vm.prank(keeper);
        treasury.execute(taskId, data);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].topics[0] == Treasury.TaskExecuted.selector) gasUsed = abi.decode(logs[i].data, (uint256));
            if (logs[i].topics[0] == Treasury.KeeperPaid.selector) {
                (ethPaid, tenaxPaid) = abi.decode(logs[i].data, (uint256, uint256));
            }
        }
    }

    function _work(uint256 writes) internal pure returns (bytes memory) {
        return abi.encodeCall(MockTaskTarget.work, (writes));
    }

    // --- keeper rewards ----------------------------------------------------------

    function test_execute_runsTheTaskAndRefundsGasWithMargin() public {
        _fundWeth(1 ether);
        bytes memory data = _work(5);
        (uint256 gasUsed, uint256 ethPaid,) = _execute(WORK, data);

        assertEq(target.calls(), 1);
        assertGt(gasUsed, treasury.GAS_OVERHEAD());
        uint256 expected = gasUsed * 0.006 gwei * 15_000 / 10_000;
        assertEq(ethPaid, expected);
        assertEq(ethPaid, treasury.keeperReward(gasUsed, data.length + 100));
        assertEq(weth.balanceOf(keeper), ethPaid);
        assertEq(treasury.keeperSpent(0), ethPaid);
        assertEq(treasury.totalKeeperEth(), ethPaid);
    }

    function test_keeperReward_capsTheGasPriceAtBaseFeePlusTip() public {
        _fundWeth(1 ether);
        vm.txGasPrice(50 gwei); // an inflated tip to the sequencer is not refunded
        (uint256 gasUsed, uint256 ethPaid,) = _execute(WORK, _work(1));
        assertEq(ethPaid, gasUsed * (0.005 gwei + 0.01 gwei) * 15_000 / 10_000);
    }

    function test_keeperReward_includesTheL1DataFee() public {
        _fundWeth(1 ether);
        gasOracle.setL1Fee(2e12);
        (uint256 gasUsed, uint256 ethPaid,) = _execute(WORK, _work(1));
        assertEq(ethPaid, (gasUsed * 0.006 gwei + 2e12) * 15_000 / 10_000);
    }

    function test_keeperReward_isCappedPerCall() public {
        _fundWeth(1 ether);
        vm.fee(100 gwei);
        vm.txGasPrice(100 gwei);
        (, uint256 ethPaid,) = _execute(WORK, _work(1));
        assertEq(ethPaid, treasury.keeperParams().capPerCall);
    }

    function test_keeperReward_stopsAtTheMonthlyBudget() public {
        _fundWeth(1 ether);
        vm.fee(100 gwei);
        vm.txGasPrice(100 gwei);
        uint256 cap = treasury.keeperParams().capPerCall; // 0.0005 ETH against a 0.02 ETH budget
        for (uint256 i; i < 40; ++i) {
            _execute(WORK, _work(1));
        }
        assertEq(treasury.keeperSpent(0), 40 * cap);
        (, uint256 ethPaid, uint256 tenaxPaid) = _execute(WORK, _work(1));
        assertEq(ethPaid + tenaxPaid, 0, "budget exhausted: the task runs unpaid");
        assertEq(target.calls(), 41);

        vm.warp(GENESIS + 30 days);
        (, ethPaid,) = _execute(WORK, _work(1));
        assertEq(ethPaid, cap, "a new period restores the budget");
    }

    function test_keeperReward_zeroGasPricePaysNothing() public {
        _fundWeth(1 ether);
        vm.fee(0);
        vm.txGasPrice(0);
        (, uint256 ethPaid, uint256 tenaxPaid) = _execute(WORK, _work(1));
        assertEq(ethPaid + tenaxPaid, 0);
    }

    function test_withoutWeth_keeperIsPaidLockedTenaxFromTheAllowance() public {
        (, uint256 ethPaid, uint256 tenaxPaid) = _execute(WORK, _work(1));
        assertEq(ethPaid, 0);
        assertEq(tenaxPaid, 250e18);
        (uint256 amount, uint256 granted, uint256 end) = escrow.locked(keeper);
        assertEq(amount, 250e18);
        assertEq(granted, 250e18, "cannot exit early");
        assertEq(end, (vm.getBlockTimestamp() + 52 weeks) / 1 weeks * 1 weeks);
        assertEq(tenax.balanceOf(keeper), 0);
        assertEq(treasury.allowanceUsed(0), 250e18);
        assertEq(treasury.totalKeeperTenax(), 250e18);
    }

    function test_tenaxReward_isLimitedByTheSeasonAllowance() public {
        vm.warp(GENESIS + 59 * SEASON);
        vm.prank(governance);
        treasury.setKeeperParams(Treasury.KeeperParams(0.01 gwei, 0.0005 ether, 0.02 ether, 2500e18));
        uint256 allowance = treasury.allowanceOf(59);
        uint256 calls = allowance / 2500e18;
        for (uint256 i; i < calls; ++i) {
            _execute(WORK, _work(0));
        }
        (,, uint256 tenaxPaid) = _execute(WORK, _work(0));
        assertEq(tenaxPaid, allowance - calls * 2500e18, "the rest of the allowance");
        (,, tenaxPaid) = _execute(WORK, _work(0));
        assertEq(tenaxPaid, 0);
        assertEq(treasury.allowanceUsed(59), allowance);

        vm.warp(GENESIS + 60 * SEASON); // season 60: the reserve is fully released
        (,, tenaxPaid) = _execute(WORK, _work(1));
        assertEq(tenaxPaid, 0);
    }

    function test_tenaxReward_skippedWhenTheKeeperHasAnExpiredLock() public {
        tenax.transfer(keeper, 100e18);
        vm.startPrank(keeper);
        tenax.approve(address(escrow), 100e18);
        escrow.createLock(100e18, vm.getBlockTimestamp() + 2 weeks);
        vm.stopPrank();
        vm.warp(vm.getBlockTimestamp() + 3 weeks);

        (,, uint256 tenaxPaid) = _execute(WORK, _work(1));
        assertEq(tenaxPaid, 0);
        assertEq(target.calls(), 1, "the task still ran");
        assertEq(treasury.allowanceUsed(0), 0);
        assertEq(treasury.totalKeeperTenax(), 0);
        assertEq(tenax.allowance(address(treasury), address(escrow)), 0);
    }

    // --- task checks -------------------------------------------------------------

    function test_RevertWhen_taskIsUnknownOrSelectorDiffers() public {
        vm.startPrank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Treasury.UnknownTask.selector, 5));
        treasury.execute(5, _work(1));
        vm.expectRevert(Treasury.InvalidCalldata.selector);
        treasury.execute(WORK, abi.encodeCall(MockTaskTarget.fail, ()));
        vm.expectRevert(Treasury.InvalidCalldata.selector);
        treasury.execute(WORK, hex"0102");
        vm.stopPrank();
    }

    /// @dev Padding would be ignored by the call but would inflate the L1 data fee refunded to the keeper.
    function test_RevertWhen_calldataIsPadded() public {
        _fundWeth(1 ether);
        gasOracle.setL1Fee(1e12);
        bytes memory padded = bytes.concat(_work(1), new bytes(2000));
        vm.prank(keeper);
        vm.expectRevert(Treasury.InvalidCalldata.selector);
        treasury.execute(WORK, padded);
    }

    function test_RevertWhen_taskRunsBeforeItsInterval() public {
        _execute(DAILY_WORK, _work(1));
        uint256 nextRun = vm.getBlockTimestamp() + 1 days;
        vm.warp(nextRun - 1);
        vm.prank(keeper);
        vm.expectRevert(abi.encodeWithSelector(Treasury.TooSoon.selector, nextRun));
        treasury.execute(DAILY_WORK, _work(1));
        vm.warp(nextRun);
        _execute(DAILY_WORK, _work(1));
        assertEq(target.calls(), 2);
    }

    function test_RevertWhen_theTaskFails() public {
        vm.prank(keeper);
        vm.expectRevert(MockTaskTarget.TaskFailed.selector);
        treasury.execute(FAIL, abi.encodeCall(MockTaskTarget.fail, ()));
    }

    function test_RevertWhen_notInitialized() public {
        Treasury fresh = new Treasury(IBurnableERC20(address(tenax)), IWETH(address(weth)), escrow, governance);
        vm.expectRevert(Treasury.NotInitialized.selector);
        fresh.execute(0, _work(1));
    }

    // --- seasons -----------------------------------------------------------------

    function _closeSeasonZero(uint256 ethReceived, bool withParticipant) internal returns (uint256 topUp) {
        if (ethReceived != 0) {
            vm.deal(address(this), ethReceived);
            weth.deposit{value: ethReceived}();
            weth.approve(address(rewards), ethReceived);
            rewards.depositEth(ethReceived);
        }
        if (withParticipant) {
            registry.setContribution(alice, 0, 1e8);
            vm.warp(rewards.registrationStart(0));
            _execute(REGISTER, abi.encodeCall(SeasonRewards.register, (alice, 0)));
        }
        vm.warp(rewards.registrationStart(0) + rewards.REGISTRATION_PERIOD());
        uint256 before = tenax.balanceOf(address(rewards));
        _execute(CLOSE, abi.encodeCall(SeasonRewards.closeSeason, (0)));
        topUp = tenax.balanceOf(address(rewards)) - before;
    }

    function test_settleSeason_topsUpTheWholeAllowanceWithoutRevenue() public {
        uint256 supplyBefore = tenax.totalSupply();
        uint256 topUp = _closeSeasonZero(0, true);
        // Registration and closing run during season 1, so their keepers are paid from season 1's allowance.
        assertEq(topUp, treasury.allowanceOf(0));
        assertEq(treasury.allowanceUsed(1), 2 * 250e18);
        assertEq(rewards.seasonInfo(0).tenaxBudget, topUp);
        assertEq(rewards.topUpsReceived(), topUp);
        assertEq(treasury.allowanceUsed(0), treasury.allowanceOf(0));
        assertEq(treasury.nextSeasonToSettle(), 1);
        assertEq(tenax.totalSupply(), supplyBefore, "nothing burned");
    }

    function test_settleSeason_topUpShrinksWithRevenue() public {
        uint256 supplyBefore = tenax.totalSupply();
        uint256 topUp = _closeSeasonZero(0.035 ether, true); // half the target
        uint256 available = treasury.allowanceOf(0);
        assertEq(topUp, available / 2);
        assertEq(supplyBefore - tenax.totalSupply(), available - available / 2, "the rest is burned");
        assertEq(treasury.totalTopUps(), topUp);
        assertEq(treasury.totalBurned(), available - available / 2);
    }

    function test_settleSeason_noTopUpAtOrAboveTarget() public {
        uint256 supplyBefore = tenax.totalSupply();
        uint256 topUp = _closeSeasonZero(0.07 ether, true);
        assertEq(topUp, 0);
        assertEq(supplyBefore - tenax.totalSupply(), treasury.allowanceOf(0));
    }

    function test_settleSeason_burnsEverythingWithoutParticipants() public {
        uint256 supplyBefore = tenax.totalSupply();
        uint256 topUp = _closeSeasonZero(0, false);
        assertEq(topUp, 0);
        assertEq(supplyBefore - tenax.totalSupply(), treasury.allowanceOf(0));
    }

    function test_claim_deliversTheTopUpLocked() public {
        uint256 topUp = _closeSeasonZero(0, true);
        vm.prank(alice);
        rewards.claim(0);
        (uint256 amount, uint256 granted,) = escrow.locked(alice);
        assertEq(amount, topUp); // no L1 block passed, so no emission
        assertEq(granted, topUp);
    }

    function test_RevertWhen_settleSeasonIsNotCalledBySeasonRewards() public {
        vm.expectRevert(Treasury.NotSeasonRewards.selector);
        treasury.settleSeason(0, 0, true);
    }

    function test_RevertWhen_settlingOutOfOrder() public {
        vm.prank(address(rewards));
        vm.expectRevert(abi.encodeWithSelector(Treasury.NotNextSeason.selector, 0));
        treasury.settleSeason(1, 0, true);
    }

    function test_allowance_releasesTheReserveOverSixtySeasons() public view {
        uint256 total;
        for (uint256 s; s < 61; ++s) {
            total += treasury.allowanceOf(s);
        }
        assertEq(total, RESERVE);
        assertEq(treasury.allowanceOf(0), 333_333_333_333_333_333_333_333);
        assertEq(treasury.allowanceOf(59), RESERVE - 59 * treasury.allowanceOf(0));
        assertEq(treasury.allowanceOf(60), 0);
    }

    // --- governance and setup ----------------------------------------------------

    function test_defaults() public view {
        Treasury.KeeperParams memory p = treasury.keeperParams();
        assertEq(p.maxTip, 0.01 gwei);
        assertEq(p.capPerCall, 0.0005 ether);
        assertEq(p.monthlyBudget, 0.02 ether);
        assertEq(p.tenaxReward, 250e18);
        assertEq(treasury.revenueTarget(), 0.07 ether);
        assertEq(treasury.ethReserveTarget(), 0.06 ether);
        assertEq(treasury.taskCount(), 5);
        assertEq(treasury.task(CLOSE).target, address(rewards));
    }

    function test_setters_enforceBoundsAndGovernance() public {
        vm.expectRevert(Treasury.NotGovernance.selector);
        treasury.setRevenueTarget(1 ether);
        vm.expectRevert(Treasury.NotGovernance.selector);
        treasury.setKeeperParams(Treasury.KeeperParams(0, 0.001 ether, 0.1 ether, 0));

        vm.startPrank(governance);
        treasury.setRevenueTarget(1 ether);
        assertEq(treasury.revenueTarget(), 1 ether);
        vm.expectRevert(Treasury.OutOfBounds.selector);
        treasury.setRevenueTarget(0.009 ether);
        vm.expectRevert(Treasury.OutOfBounds.selector);
        treasury.setRevenueTarget(10.1 ether);

        Treasury.KeeperParams[5] memory invalid = [
            Treasury.KeeperParams(1.1 gwei, 0.001 ether, 0.1 ether, 0),
            Treasury.KeeperParams(0, 0.000_009 ether, 0.1 ether, 0),
            Treasury.KeeperParams(0, 0.011 ether, 0.1 ether, 0),
            Treasury.KeeperParams(0, 0.001 ether, 0.0009 ether, 0),
            Treasury.KeeperParams(0, 0.001 ether, 1.1 ether, 2501e18)
        ];
        for (uint256 i; i < invalid.length; ++i) {
            vm.expectRevert(Treasury.OutOfBounds.selector);
            treasury.setKeeperParams(invalid[i]);
        }
        treasury.setKeeperParams(Treasury.KeeperParams(0, 0.001 ether, 0.1 ether, 0));
        vm.stopPrank();
        assertEq(treasury.ethReserveTarget(), 0.3 ether);
    }

    function test_RevertWhen_initializedTwiceOrWrongly() public {
        vm.expectRevert(Treasury.AlreadyInitialized.selector);
        treasury.initialize(rewards, _tasks());

        Treasury fresh = new Treasury(IBurnableERC20(address(tenax)), IWETH(address(weth)), escrow, governance);
        vm.prank(keeper);
        vm.expectRevert(Treasury.NotInitializer.selector);
        fresh.initialize(rewards, _tasks());
        vm.expectRevert(Treasury.ZeroAddress.selector);
        fresh.initialize(SeasonRewards(payable(address(0))), _tasks());
        vm.expectRevert(Treasury.TreasuryMismatch.selector);
        fresh.initialize(rewards, _tasks());

        Treasury.Task[] memory tasks = new Treasury.Task[](1);
        SeasonRewards other = new SeasonRewards(
            tenax,
            IWETH(address(weth)),
            escrow,
            ForecastRegistry(address(registry)),
            new EmissionSchedule(L1_START),
            fresh
        );
        vm.expectRevert(Treasury.ZeroAddress.selector);
        fresh.initialize(other, tasks);
    }

    function test_RevertWhen_constructorArgumentsAreInvalid() public {
        IBurnableERC20 t = IBurnableERC20(address(tenax));
        IWETH w = IWETH(address(weth));
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(IBurnableERC20(address(0)), w, escrow, governance);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(t, IWETH(address(0)), escrow, governance);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(t, w, VotingEscrow(address(0)), governance);
        vm.expectRevert(Treasury.ZeroAddress.selector);
        new Treasury(t, w, escrow, address(0));

        TenaxToken other = new TenaxToken(address(this));
        vm.expectRevert(Treasury.TokenMismatch.selector);
        new Treasury(IBurnableERC20(address(other)), w, escrow, governance);
    }
}
