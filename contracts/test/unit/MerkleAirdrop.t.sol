// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MerkleAirdrop} from "../../src/distribution/MerkleAirdrop.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {MerkleHelper} from "../utils/MerkleHelper.sol";
import {Test} from "forge-std/Test.sol";

contract MerkleAirdropTest is Test {
    uint256 internal constant BUCKET = 10_000_000e18;
    uint256 internal constant START = 1_800_000_000;

    TenaxToken internal tenax;
    VotingEscrow internal escrow;
    MerkleAirdrop internal airdrop;
    address internal launcher = makeAddr("launcher");

    address[4] internal accounts = [makeAddr("alice"), makeAddr("bob"), makeAddr("carol"), makeAddr("dave")];
    uint256[4] internal amounts = [uint256(4_000_000e18), 3_000_000e18, 2_000_000e18, 1_000_000e18];
    bytes32[] internal leaves;

    function setUp() public {
        vm.warp(START);
        tenax = new TenaxToken(address(this));
        escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        for (uint256 i; i < 4; ++i) {
            leaves.push(MerkleHelper.leaf(accounts[i], amounts[i]));
        }
        airdrop = new MerkleAirdrop(IBurnableERC20(address(tenax)), escrow, MerkleHelper.root(leaves), launcher);
        address[] memory distributors = new address[](1);
        distributors[0] = address(airdrop);
        escrow.initializeDistributors(distributors);
        tenax.transfer(address(airdrop), BUCKET);
        vm.prank(launcher);
        airdrop.open();
    }

    function _claim(uint256 i, uint256 lockDuration) internal {
        bytes32[] memory proof = MerkleHelper.proof(leaves, i);
        vm.prank(accounts[i]);
        airdrop.claim(amounts[i], lockDuration, proof);
    }

    // --- claims ------------------------------------------------------------------

    function test_claim_fractionDependsOnTheLockDuration() public {
        uint256 burned = _claimAndCheck(0, 26 weeks, 5000) + _claimAndCheck(1, 52 weeks, 7500)
            + _claimAndCheck(2, 104 weeks, 10_000);
        assertEq(burned, 2_000_000e18 + 750_000e18);
        assertEq(tenax.balanceOf(address(airdrop)), BUCKET - 4_000_000e18 - 3_000_000e18 - 2_000_000e18);
    }

    function _claimAndCheck(uint256 i, uint256 duration, uint256 fraction) internal returns (uint256 burned) {
        uint256 supplyBefore = tenax.totalSupply();
        _claim(i, duration);

        uint256 received = amounts[i] * fraction / 10_000;
        (uint256 amount, uint256 granted, uint256 end) = escrow.locked(accounts[i]);
        assertEq(amount, received);
        assertEq(granted, received, "airdrop tokens are granted");
        assertEq(end, (vm.getBlockTimestamp() + duration) / 1 weeks * 1 weeks);
        burned = supplyBefore - tenax.totalSupply();
        assertEq(burned, amounts[i] - received, "unreceived fraction burned");
        assertEq(tenax.balanceOf(accounts[i]), 0, "nothing liquid");
        assertTrue(airdrop.claimed(accounts[i]));
    }

    function test_claim_cannotExitEarly() public {
        _claim(0, 26 weeks);
        vm.prank(accounts[0]);
        vm.expectRevert(VotingEscrow.NoVoluntaryBalance.selector);
        escrow.withdrawEarly();
    }

    function test_claim_addsToAnExistingLockWithoutShorteningIt() public {
        address alice = accounts[0];
        tenax.transfer(alice, 1000e18);
        vm.startPrank(alice);
        tenax.approve(address(escrow), 1000e18);
        escrow.createLock(1000e18, vm.getBlockTimestamp() + 104 weeks);
        vm.stopPrank();
        (,, uint256 longEnd) = escrow.locked(alice);

        _claim(0, 26 weeks);
        (uint256 amount, uint256 granted, uint256 end) = escrow.locked(alice);
        assertEq(amount, 1000e18 + 2_000_000e18);
        assertEq(granted, 2_000_000e18);
        assertEq(end, longEnd);
    }

    function test_RevertWhen_lockDurationIsNotOffered() public {
        bytes32[] memory proof = MerkleHelper.proof(leaves, 0);
        vm.startPrank(accounts[0]);
        vm.expectRevert(abi.encodeWithSelector(MerkleAirdrop.InvalidLockDuration.selector, 30 weeks));
        airdrop.claim(amounts[0], 30 weeks, proof);
        vm.expectRevert(abi.encodeWithSelector(MerkleAirdrop.InvalidLockDuration.selector, 104 weeks + 1));
        airdrop.claim(amounts[0], 104 weeks + 1, proof);
        vm.stopPrank();
    }

    function test_RevertWhen_proofIsInvalid() public {
        bytes32[] memory proof = MerkleHelper.proof(leaves, 0);
        vm.prank(accounts[0]);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        airdrop.claim(amounts[0] + 1, 52 weeks, proof); // wrong amount

        vm.prank(accounts[1]);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        airdrop.claim(amounts[0], 52 weeks, proof); // someone else's leaf
    }

    function test_RevertWhen_claimingTwice() public {
        _claim(1, 52 weeks);
        bytes32[] memory proof = MerkleHelper.proof(leaves, 1);
        vm.prank(accounts[1]);
        vm.expectRevert(MerkleAirdrop.AlreadyClaimed.selector);
        airdrop.claim(amounts[1], 52 weeks, proof);
    }

    // --- opening and deadline ----------------------------------------------------

    function test_RevertWhen_claimingBeforeOpening() public {
        MerkleAirdrop closed =
            new MerkleAirdrop(IBurnableERC20(address(tenax)), escrow, MerkleHelper.root(leaves), launcher);
        assertEq(closed.claimDeadline(), 0);
        bytes32[] memory proof = MerkleHelper.proof(leaves, 0);
        vm.prank(accounts[0]);
        vm.expectRevert(MerkleAirdrop.NotOpen.selector);
        closed.claim(amounts[0], 52 weeks, proof);
    }

    function test_open_onlyOnceByTheOpener() public {
        assertEq(airdrop.claimDeadline(), START + 90 days);
        vm.prank(launcher);
        vm.expectRevert(MerkleAirdrop.AlreadyOpened.selector);
        airdrop.open();

        MerkleAirdrop closed =
            new MerkleAirdrop(IBurnableERC20(address(tenax)), escrow, MerkleHelper.root(leaves), launcher);
        vm.expectRevert(MerkleAirdrop.NotOpener.selector);
        closed.open();
    }

    function test_RevertWhen_claimingAfterTheDeadline() public {
        vm.warp(airdrop.claimDeadline() - 1);
        _claim(0, 52 weeks);

        vm.warp(airdrop.claimDeadline());
        bytes32[] memory proof = MerkleHelper.proof(leaves, 1);
        vm.prank(accounts[1]);
        vm.expectRevert(MerkleAirdrop.ClaimPeriodOver.selector);
        airdrop.claim(amounts[1], 52 weeks, proof);
    }

    function test_burnUnclaimed_burnsEverythingLeftAfterTheDeadline() public {
        _claim(0, 104 weeks);
        uint256 deadline = airdrop.claimDeadline();
        vm.warp(deadline - 1);
        vm.expectRevert(abi.encodeWithSelector(MerkleAirdrop.ClaimPeriodNotOver.selector, deadline));
        airdrop.burnUnclaimed();

        vm.warp(deadline);
        uint256 supplyBefore = tenax.totalSupply();
        airdrop.burnUnclaimed();
        assertEq(tenax.balanceOf(address(airdrop)), 0);
        assertEq(supplyBefore - tenax.totalSupply(), BUCKET - 4_000_000e18);
    }

    function test_RevertWhen_burningBeforeOpening() public {
        MerkleAirdrop closed =
            new MerkleAirdrop(IBurnableERC20(address(tenax)), escrow, MerkleHelper.root(leaves), launcher);
        vm.warp(START + 1000 days);
        vm.expectRevert(abi.encodeWithSelector(MerkleAirdrop.ClaimPeriodNotOver.selector, 0));
        closed.burnUnclaimed();
    }

    // --- setup -------------------------------------------------------------------

    function test_RevertWhen_constructorArgumentsAreInvalid() public {
        IBurnableERC20 token = IBurnableERC20(address(tenax));
        vm.expectRevert(MerkleAirdrop.ZeroAddress.selector);
        new MerkleAirdrop(IBurnableERC20(address(0)), escrow, bytes32(0), launcher);
        vm.expectRevert(MerkleAirdrop.ZeroAddress.selector);
        new MerkleAirdrop(token, VotingEscrow(address(0)), bytes32(0), launcher);
        vm.expectRevert(MerkleAirdrop.ZeroAddress.selector);
        new MerkleAirdrop(token, escrow, bytes32(0), address(0));

        TenaxToken other = new TenaxToken(address(this));
        vm.expectRevert(MerkleAirdrop.TokenMismatch.selector);
        new MerkleAirdrop(IBurnableERC20(address(other)), escrow, bytes32(0), launcher);
    }

    function testFuzz_receivedPlusBurnedIsTheAllocation(uint256 maxAmount, uint8 choice) public {
        maxAmount = bound(maxAmount, 2, BUCKET);
        uint256 duration = choice % 3 == 0 ? 26 weeks : choice % 3 == 1 ? 52 weeks : 104 weeks;
        address claimer = makeAddr("claimer");

        bytes32[] memory pair = new bytes32[](2);
        pair[0] = MerkleHelper.leaf(claimer, maxAmount);
        pair[1] = MerkleHelper.leaf(address(1), 0);
        VotingEscrow freshEscrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        MerkleAirdrop drop =
            new MerkleAirdrop(IBurnableERC20(address(tenax)), freshEscrow, MerkleHelper.root(pair), launcher);
        address[] memory distributors = new address[](1);
        distributors[0] = address(drop);
        freshEscrow.initializeDistributors(distributors);
        tenax.transfer(address(drop), maxAmount);
        vm.prank(launcher);
        drop.open();

        uint256 supplyBefore = tenax.totalSupply();
        bytes32[] memory proof = MerkleHelper.proof(pair, 0);
        vm.prank(claimer);
        drop.claim(maxAmount, duration, proof);

        (uint256 locked,,) = freshEscrow.locked(claimer);
        assertEq(locked, maxAmount * drop.fractionBps(duration) / 10_000);
        assertEq(locked + supplyBefore - tenax.totalSupply(), maxAmount);
        assertEq(tenax.balanceOf(address(drop)), 0);
    }
}
