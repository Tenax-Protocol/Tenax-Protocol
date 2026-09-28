// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {ForecastRegistry} from "../../src/forecast/ForecastRegistry.sol";
import {IAggregatorV3, OracleAdapter} from "../../src/forecast/OracleAdapter.sol";
import {TenaxGovernor} from "../../src/governance/TenaxGovernor.sol";
import {TenaxTimelock} from "../../src/governance/TenaxTimelock.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IEthDepositor, RevenueRouter} from "../../src/revenue/RevenueRouter.sol";
import {Treasury} from "../../src/revenue/Treasury.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {MockEthDepositor} from "../mocks/MockEthDepositor.sol";
import {MockWETH} from "../mocks/MockWETH.sol";
import {IGovernor} from "@openzeppelin/contracts/governance/IGovernor.sol";
import {IVotes} from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Governance deployed the way the launch will deploy it: the timelock starts with the deployer as admin, the
/// governor gets the proposer and canceller roles, the Safe the canceller role, execution is open to anyone and the
/// deployer renounces its admin role. The protocol's parameter contracts answer to the timelock. Voters lock
/// TENAX for two years.
abstract contract GovernanceTestBase is Test {
    uint256 internal constant START = 1_800_000_000;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    TenaxTimelock internal timelock;
    TenaxGovernor internal governor;

    RevenueRouter internal router;
    Treasury internal treasury;
    ForecastRegistry internal registry;

    address internal safe = makeAddr("safe");
    address internal alice = makeAddr("alice"); // 2,000,000 TENAX
    address internal bob = makeAddr("bob"); // 500,000 TENAX
    address internal carol = makeAddr("carol"); // 150,000 TENAX
    address internal dave = makeAddr("dave"); // 50,000 TENAX, below the proposal threshold
    address internal executor = makeAddr("executor");

    function setUp() public virtual {
        vm.warp(START);
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));

        address[] memory none = new address[](0);
        address[] memory anyone = new address[](1); // address(0): anyone can execute
        timelock = new TenaxTimelock(2 days, none, anyone, address(this), safe);
        governor = new TenaxGovernor(IVotes(address(escrow)), timelock, safe);
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), address(governor));
        timelock.grantRole(timelock.CANCELLER_ROLE(), safe);
        timelock.renounceRole(timelock.DEFAULT_ADMIN_ROLE(), address(this));

        _deployGovernedContracts();

        _lock(alice, 2_000_000e18);
        _lock(bob, 500_000e18);
        _lock(carol, 150_000e18);
        _lock(dave, 50_000e18);
        vm.warp(START + 1); // proposals read voting power one second in the past
    }

    function _deployGovernedContracts() internal {
        IWETH weth = IWETH(address(new MockWETH()));
        router = new RevenueRouter(
            weth,
            IEthDepositor(address(new MockEthDepositor(weth))),
            IEthDepositor(address(new MockEthDepositor(weth))),
            makeAddr("treasury"),
            address(timelock)
        );
        treasury = new Treasury(IBurnableERC20(address(tenax)), weth, escrow, address(timelock));

        IAggregatorV3[] memory feeds = new IAggregatorV3[](1);
        feeds[0] = new MockAggregator(8);
        uint64[] memory tolerances = new uint64[](1);
        tolerances[0] = 3960;
        OracleAdapter oracle = new OracleAdapter(feeds, tolerances, IAggregatorV3(address(0)), 0);
        uint256[] memory thresholds = new uint256[](1);
        thresholds[0] = 0.02e18;
        uint256[] memory baseRates = new uint256[](1);
        baseRates[0] = 0.36e18;
        registry = new ForecastRegistry(
            IVotes(address(escrow)), oracle, address(timelock), START, 30 minutes, 48 hours, thresholds, baseRates
        );
    }

    function _lock(address voter, uint256 amount) internal {
        tenax.transfer(voter, amount);
        vm.startPrank(voter);
        tenax.approve(address(escrow), amount);
        escrow.createLock(amount, vm.getBlockTimestamp() + 104 weeks);
        vm.stopPrank();
    }

    // --- proposals ---------------------------------------------------------------

    struct Proposal {
        address[] targets;
        uint256[] values;
        bytes[] calldatas;
        string description;
    }

    function _single(address target, bytes memory data, string memory description)
        internal
        pure
        returns (Proposal memory p)
    {
        p.targets = new address[](1);
        p.targets[0] = target;
        p.values = new uint256[](1);
        p.calldatas = new bytes[](1);
        p.calldatas[0] = data;
        p.description = description;
    }

    function _propose(address proposer, Proposal memory p) internal returns (uint256 id) {
        vm.prank(proposer);
        id = governor.propose(p.targets, p.values, p.calldatas, p.description);
    }

    function _vote(address voter, uint256 id, uint8 support) internal {
        vm.prank(voter);
        governor.castVote(id, support);
    }

    function _toVoting(uint256 id) internal {
        vm.warp(governor.proposalSnapshot(id) + 1);
    }

    function _toEnd(uint256 id) internal {
        vm.warp(governor.proposalDeadline(id) + 1);
    }

    function _queue(Proposal memory p) internal returns (uint256 id) {
        id = governor.queue(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
    }

    function _execute(Proposal memory p) internal returns (uint256 id) {
        vm.prank(executor);
        id = governor.execute(p.targets, p.values, p.calldatas, keccak256(bytes(p.description)));
    }

    /// @dev Proposes as alice, who alone meets the quorum, votes in favor and queues; returns once the timelock
    /// delay has passed, ready to execute.
    function _passAndQueue(Proposal memory p) internal returns (uint256 id) {
        id = _propose(alice, p);
        _toVoting(id);
        _vote(alice, id, 1);
        _toEnd(id);
        _queue(p);
        vm.warp(governor.proposalEta(id));
    }

    function _state(uint256 id) internal view returns (IGovernor.ProposalState) {
        return governor.state(id);
    }
}
