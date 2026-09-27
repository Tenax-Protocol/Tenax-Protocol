// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {TokenTestBase} from "../utils/TokenTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

contract TenaxTokenTest is TokenTestBase {
    bytes32 internal constant EIP712_DOMAIN_TYPEHASH =
        keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)");

    // --- deployment -----------------------------------------------------------

    function test_constructor_mintsInitialSupplyToRecipient() public {
        TenaxToken fresh = new TenaxToken(distributor);
        assertEq(fresh.totalSupply(), 100_000_000e18);
        assertEq(fresh.balanceOf(distributor), 100_000_000e18);
        assertEq(fresh.INITIAL_SUPPLY(), 100_000_000e18);
    }

    function test_RevertWhen_constructorRecipientIsZero() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        new TenaxToken(address(0));
    }

    function test_metadata() public view {
        assertEq(token.name(), "Tenax Protocol");
        assertEq(token.symbol(), "TENAX");
        assertEq(token.decimals(), 18);
    }

    // --- EIP-712 domain -------------------------------------------------------

    function test_domainSeparator_matchesSpecification() public view {
        bytes32 expected = keccak256(
            abi.encode(
                EIP712_DOMAIN_TYPEHASH, keccak256("Tenax Protocol"), keccak256("1"), block.chainid, address(token)
            )
        );
        assertEq(token.DOMAIN_SEPARATOR(), expected);
    }

    function test_eip712Domain_reportsNameAndVersion() public view {
        (, string memory name, string memory version, uint256 chainId, address verifyingContract,,) =
            token.eip712Domain();
        assertEq(name, "Tenax Protocol");
        assertEq(version, "1");
        assertEq(chainId, block.chainid);
        assertEq(verifyingContract, address(token));
    }

    function test_domainSeparator_changesWithChainId() public {
        bytes32 original = token.DOMAIN_SEPARATOR();
        vm.chainId(block.chainid + 1);
        assertTrue(token.DOMAIN_SEPARATOR() != original);
    }

    // --- burning --------------------------------------------------------------

    function test_burn_reducesBalanceAndSupply() public {
        vm.prank(alice);
        token.burn(40e18);
        assertEq(token.balanceOf(alice), ALICE_BALANCE - 40e18);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY() - 40e18);
    }

    function test_burnFrom_spendsAllowance() public {
        vm.prank(alice);
        token.approve(bob, 50e18);
        vm.prank(bob);
        token.burnFrom(alice, 30e18);
        assertEq(token.allowance(alice, bob), 20e18);
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY() - 30e18);
    }

    function test_RevertWhen_burnExceedsBalance() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                IERC20Errors.ERC20InsufficientBalance.selector, alice, ALICE_BALANCE, ALICE_BALANCE + 1
            )
        );
        vm.prank(alice);
        token.burn(ALICE_BALANCE + 1);
    }

    function test_RevertWhen_burnFromWithoutAllowance() public {
        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InsufficientAllowance.selector, bob, 0, 1e18));
        vm.prank(bob);
        token.burnFrom(alice, 1e18);
    }

    // --- permit (EIP-2612) ----------------------------------------------------

    function test_permit_setsAllowanceAndIncrementsNonce() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _permitDigest(alice, bob, 500e18, 0, deadline));

        vm.prank(relayer);
        token.permit(alice, bob, 500e18, deadline, v, r, s);

        assertEq(token.allowance(alice, bob), 500e18);
        assertEq(token.nonces(alice), 1);
    }

    function test_RevertWhen_permitExpired() public {
        uint256 deadline = block.timestamp - 1;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _permitDigest(alice, bob, 500e18, 0, deadline));

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612ExpiredSignature.selector, deadline));
        token.permit(alice, bob, 500e18, deadline, v, r, s);
    }

    function test_RevertWhen_permitSignedByAnotherKey() public {
        (address mallory, uint256 malloryPk) = makeAddrAndKey("mallory");
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(malloryPk, _permitDigest(alice, bob, 500e18, 0, deadline));

        vm.expectRevert(abi.encodeWithSelector(ERC20Permit.ERC2612InvalidSigner.selector, mallory, alice));
        token.permit(alice, bob, 500e18, deadline, v, r, s);
    }

    function test_RevertWhen_permitReplayed() public {
        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _permitDigest(alice, bob, 500e18, 0, deadline));
        token.permit(alice, bob, 500e18, deadline, v, r, s);

        vm.expectRevert(); // the nonce moved on, so the recovered signer no longer matches
        token.permit(alice, bob, 500e18, deadline, v, r, s);
    }
}
