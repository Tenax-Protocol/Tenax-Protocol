// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC3009} from "../../src/token/ERC3009.sol";
import {MockERC1271Wallet} from "../mocks/MockERC1271Wallet.sol";
import {TokenTestBase} from "../utils/TokenTestBase.sol";
import {IERC20Errors} from "@openzeppelin/contracts/interfaces/draft-IERC6093.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ERC3009Test is TokenTestBase {
    // secp256k1 curve order, used to build a malleable signature.
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;

    // --- type hashes ----------------------------------------------------------

    function test_typeHashes_matchSpecification() public view {
        assertEq(
            token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(),
            0x7c7c6cdb67a18743f49ec6fa9b35f50d52ed05cbed4cc592e13b44501c1a2267
        );
        assertEq(
            token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(),
            0xd099cc98ef71107a616c4f0f941f04c322d8e254fe26b3c6668db87aae413de8
        );
        assertEq(
            token.CANCEL_AUTHORIZATION_TYPEHASH(), 0x158b0a9edf7a828aad02f63cd515c68ef2f50ba807396f6d12842833a1597429
        );
    }

    // --- transferWithAuthorization --------------------------------------------

    function test_transferWithAuthorization_movesTokensAndMarksNonce() public {
        Authorization memory auth = _defaultAuthorization();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectEmit(address(token));
        emit ERC3009.AuthorizationUsed(alice, auth.nonce);
        vm.expectEmit(address(token));
        emit IERC20.Transfer(alice, bob, auth.value);

        vm.prank(relayer);
        _transferWithAuthorization(auth, v, r, s);

        assertEq(token.balanceOf(alice), ALICE_BALANCE - auth.value);
        assertEq(token.balanceOf(bob), auth.value);
        assertTrue(token.authorizationState(alice, auth.nonce));
    }

    function test_transferWithAuthorization_acceptsBytesSignature() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        _transferWithAuthorization(auth, signature);

        assertEq(token.balanceOf(bob), auth.value);
    }

    function test_transferWithAuthorization_allowsZeroValue() public {
        Authorization memory auth = _defaultAuthorization();
        auth.value = 0;
        _transferWithAuthorization(
            auth, _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth))
        );
        assertTrue(token.authorizationState(alice, auth.nonce));
    }

    function test_RevertWhen_transferAtValidAfter() public {
        Authorization memory auth = _defaultAuthorization();
        auth.validAfter = block.timestamp;
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationNotYetValid.selector, auth.validAfter));
        _transferWithAuthorization(auth, signature);
    }

    function test_RevertWhen_transferAtValidBefore() public {
        Authorization memory auth = _defaultAuthorization();
        auth.validBefore = block.timestamp;
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationExpired.selector, auth.validBefore));
        _transferWithAuthorization(auth, signature);
    }

    function test_RevertWhen_authorizationReused() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        _transferWithAuthorization(auth, signature);

        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationUsedOrCanceled.selector, alice, auth.nonce));
        _transferWithAuthorization(auth, signature);
    }

    function test_RevertWhen_signedByAnotherKey() public {
        (, uint256 malloryPk) = makeAddrAndKey("mallory");
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(malloryPk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, signature);
        assertFalse(token.authorizationState(alice, auth.nonce));
    }

    function test_RevertWhen_valueTampered() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        auth.value += 1;

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, signature);
    }

    function test_RevertWhen_recipientTampered() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        auth.to = relayer;

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, signature);
    }

    function test_RevertWhen_receiveSignatureUsedForTransfer() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, signature);
    }

    function test_RevertWhen_signatureIsMalleable() public {
        Authorization memory auth = _defaultAuthorization();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        bytes32 highS = bytes32(SECP256K1_N - uint256(s));
        uint8 flippedV = v == 27 ? 28 : 27;

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, flippedV, r, highS);
    }

    function test_RevertWhen_signedForAnotherChain() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        vm.chainId(block.chainid + 1);

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, signature);
    }

    function test_RevertWhen_transferExceedsBalance() public {
        Authorization memory auth = _defaultAuthorization();
        auth.value = ALICE_BALANCE + 1;
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(
            abi.encodeWithSelector(IERC20Errors.ERC20InsufficientBalance.selector, alice, ALICE_BALANCE, auth.value)
        );
        _transferWithAuthorization(auth, signature);
        assertFalse(token.authorizationState(alice, auth.nonce), "a reverted transfer must not consume the nonce");
    }

    function test_RevertWhen_recipientIsZero() public {
        Authorization memory auth = _defaultAuthorization();
        auth.to = address(0);
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(abi.encodeWithSelector(IERC20Errors.ERC20InvalidReceiver.selector, address(0)));
        _transferWithAuthorization(auth, signature);
    }

    // --- receiveWithAuthorization ---------------------------------------------

    function test_receiveWithAuthorization_payeeCanSubmit() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.prank(bob);
        _receiveWithAuthorization(auth, signature);

        assertEq(token.balanceOf(bob), auth.value);
        assertTrue(token.authorizationState(alice, auth.nonce));
    }

    function test_receiveWithAuthorization_acceptsVrsSignature() public {
        Authorization memory auth = _defaultAuthorization();
        (uint8 v, bytes32 r, bytes32 s) =
            vm.sign(alicePk, _authorizationDigest(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.prank(bob);
        token.receiveWithAuthorization(alice, bob, auth.value, auth.validAfter, auth.validBefore, auth.nonce, v, r, s);

        assertEq(token.balanceOf(bob), auth.value);
    }

    function test_RevertWhen_receiveSubmittedByNonPayee() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.RECEIVE_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009CallerMustBePayee.selector, relayer, bob));
        vm.prank(relayer);
        _receiveWithAuthorization(auth, signature);
    }

    function test_RevertWhen_transferSignatureUsedForReceive() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        vm.prank(bob);
        _receiveWithAuthorization(auth, signature);
    }

    // --- cancelAuthorization --------------------------------------------------

    function test_cancelAuthorization_blocksLaterUse() public {
        Authorization memory auth = _defaultAuthorization();
        bytes memory transferSignature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _cancelDigest(alice, auth.nonce));

        vm.expectEmit(address(token));
        emit ERC3009.AuthorizationCanceled(alice, auth.nonce);
        vm.prank(relayer);
        token.cancelAuthorization(alice, auth.nonce, v, r, s);

        assertTrue(token.authorizationState(alice, auth.nonce));
        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationUsedOrCanceled.selector, alice, auth.nonce));
        _transferWithAuthorization(auth, transferSignature);
    }

    function test_cancelAuthorization_acceptsBytesSignature() public {
        bytes32 nonce = keccak256("to-cancel");
        token.cancelAuthorization(alice, nonce, _signBytes(alicePk, _cancelDigest(alice, nonce)));
        assertTrue(token.authorizationState(alice, nonce));
    }

    function test_RevertWhen_cancelUsedAuthorization() public {
        Authorization memory auth = _defaultAuthorization();
        _transferWithAuthorization(
            auth, _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth))
        );
        bytes memory cancelSignature = _signBytes(alicePk, _cancelDigest(alice, auth.nonce));

        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationUsedOrCanceled.selector, alice, auth.nonce));
        token.cancelAuthorization(alice, auth.nonce, cancelSignature);
    }

    function test_RevertWhen_cancelSignedByAnotherKey() public {
        (, uint256 malloryPk) = makeAddrAndKey("mallory");
        bytes32 nonce = keccak256("nonce");
        bytes memory signature = _signBytes(malloryPk, _cancelDigest(alice, nonce));

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        token.cancelAuthorization(alice, nonce, signature);
        assertFalse(token.authorizationState(alice, nonce));
    }

    // --- contract wallets (ERC-1271) ------------------------------------------

    function test_transferWithAuthorization_fromContractWallet() public {
        MockERC1271Wallet wallet = new MockERC1271Wallet(alice);
        vm.prank(distributor);
        token.transfer(address(wallet), 500e18);

        Authorization memory auth = _defaultAuthorization();
        auth.from = address(wallet);
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        _transferWithAuthorization(auth, signature);

        assertEq(token.balanceOf(bob), auth.value);
        assertTrue(token.authorizationState(address(wallet), auth.nonce));
    }

    function test_RevertWhen_contractWalletRejectsSignature() public {
        (, uint256 malloryPk) = makeAddrAndKey("mallory");
        MockERC1271Wallet wallet = new MockERC1271Wallet(alice);
        vm.prank(distributor);
        token.transfer(address(wallet), 500e18);

        Authorization memory auth = _defaultAuthorization();
        auth.from = address(wallet);
        bytes memory signature =
            _signBytes(malloryPk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, signature);
    }

    // --- independence from permit ---------------------------------------------

    function test_authorizationNoncesAreIndependentFromPermitNonces() public {
        Authorization memory auth = _defaultAuthorization();
        auth.nonce = bytes32(0);
        _transferWithAuthorization(
            auth, _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth))
        );
        assertEq(token.nonces(alice), 0, "EIP-3009 must not consume permit nonces");

        uint256 deadline = block.timestamp + 1 hours;
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(alicePk, _permitDigest(alice, bob, 1e18, 0, deadline));
        token.permit(alice, bob, 1e18, deadline, v, r, s);
        assertEq(token.nonces(alice), 1);
    }

    function test_authorizationsCanBeUsedInAnyOrder() public {
        Authorization memory first = _defaultAuthorization();
        Authorization memory second = _defaultAuthorization();
        second.nonce = keccak256("nonce-2");
        bytes memory firstSignature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), first));
        bytes memory secondSignature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), second));

        _transferWithAuthorization(second, secondSignature);
        _transferWithAuthorization(first, firstSignature);

        assertEq(token.balanceOf(bob), first.value + second.value);
    }
}
