// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MerkleAirdrop} from "../../src/distribution/MerkleAirdrop.sol";
import {IBurnableERC20, VotingEscrow} from "../../src/escrow/VotingEscrow.sol";
import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Claims against a tree built by the off-chain airdrop tool (offchain/src/airdrop), proving that its leaf
/// encoding, pair hashing and proofs are the ones MerkleAirdrop verifies. The fixture has an odd number of leaves,
/// so it also covers a node that moves up a level unpaired.
contract AirdropTreeTest is Test {
    string internal constant FIXTURE = "test/fixtures/airdrop-tree.json";

    function test_offchainTree_everyRecipientClaims() public {
        string memory json = vm.readFile(FIXTURE);
        bytes32 root = vm.parseJsonBytes32(json, ".root");
        uint256 count = _count(json);

        TenaxToken tenax = new TenaxToken(address(this));
        VotingEscrow escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        MerkleAirdrop airdrop = new MerkleAirdrop(IBurnableERC20(address(tenax)), escrow, root, address(this));
        address[] memory distributors = new address[](1);
        distributors[0] = address(airdrop);
        escrow.initializeDistributors(distributors);
        tenax.transfer(address(airdrop), 10_000_000e18);
        airdrop.open();

        for (uint256 i; i < count; ++i) {
            string memory path = string.concat(".recipients[", vm.toString(i), "]");
            address account = vm.parseJsonAddress(json, string.concat(path, ".account"));
            uint256 amount = vm.parseJsonUint(json, string.concat(path, ".amount"));
            bytes32[] memory proof = vm.parseJsonBytes32Array(json, string.concat(path, ".proof"));

            vm.prank(account);
            airdrop.claim(amount, 104 weeks, proof);
            (uint256 locked,,) = escrow.locked(account);
            assertEq(locked, amount, "full allocation locked for 104 weeks");
        }
        assertEq(count, 7);
    }

    function test_RevertWhen_anAmountIsAltered() public {
        string memory json = vm.readFile(FIXTURE);
        TenaxToken tenax = new TenaxToken(address(this));
        VotingEscrow escrow = new VotingEscrow(IBurnableERC20(address(tenax)));
        MerkleAirdrop airdrop = new MerkleAirdrop(
            IBurnableERC20(address(tenax)), escrow, vm.parseJsonBytes32(json, ".root"), address(this)
        );
        airdrop.open();
        address account = vm.parseJsonAddress(json, ".recipients[0].account");
        uint256 amount = vm.parseJsonUint(json, ".recipients[0].amount");
        bytes32[] memory proof = vm.parseJsonBytes32Array(json, ".recipients[0].proof");
        vm.prank(account);
        vm.expectRevert(MerkleAirdrop.InvalidProof.selector);
        airdrop.claim(amount + 1, 104 weeks, proof);
    }

    function _count(string memory json) private view returns (uint256 n) {
        while (vm.keyExistsJson(json, string.concat(".recipients[", vm.toString(n), "]"))) ++n;
    }
}
