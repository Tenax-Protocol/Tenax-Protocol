// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC3009} from "../../src/token/ERC3009.sol";
import {TokenTestBase} from "../utils/TokenTestBase.sol";

contract ERC3009FuzzTest is TokenTestBase {
    uint256 internal constant SECP256K1_N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141;
    uint256 internal constant SIGNER_BALANCE = 1000e18;

    function _fundedSigner(uint256 privateKey) internal returns (address signer, uint256 key) {
        key = bound(privateKey, 1, SECP256K1_N - 1);
        signer = vm.addr(key);
        // The fuzzer can pick up keys stored by the test itself (such as alice's); start from an empty account.
        vm.assume(signer != distributor && token.balanceOf(signer) == 0);
        vm.prank(distributor);
        token.transfer(signer, SIGNER_BALANCE);
    }

    function testFuzz_transferWithAuthorization(
        uint256 privateKey,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce
    ) public {
        (address signer, uint256 key) = _fundedSigner(privateKey);
        vm.assume(to != address(0) && to != signer);
        value = bound(value, 0, SIGNER_BALANCE);
        validAfter = bound(validAfter, 0, block.timestamp - 1);
        validBefore = bound(validBefore, block.timestamp + 1, type(uint256).max);

        Authorization memory auth = Authorization(signer, to, value, validAfter, validBefore, nonce);
        bytes memory signature =
            _signBytes(key, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        uint256 recipientBefore = token.balanceOf(to);

        vm.prank(relayer);
        _transferWithAuthorization(auth, signature);

        assertEq(token.balanceOf(signer), SIGNER_BALANCE - value);
        assertEq(token.balanceOf(to), recipientBefore + value);
        assertTrue(token.authorizationState(signer, nonce));

        vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationUsedOrCanceled.selector, signer, nonce));
        _transferWithAuthorization(auth, signature);
    }

    function testFuzz_validityWindow(uint256 validAfter, uint256 validBefore, uint256 timestamp) public {
        timestamp = bound(timestamp, 1, type(uint64).max);
        validAfter = bound(validAfter, 0, type(uint64).max);
        validBefore = bound(validBefore, 0, type(uint64).max);

        Authorization memory auth = _defaultAuthorization();
        auth.validAfter = validAfter;
        auth.validBefore = validBefore;
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));
        vm.warp(timestamp);

        if (timestamp <= validAfter) {
            vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationNotYetValid.selector, validAfter));
        } else if (timestamp >= validBefore) {
            vm.expectRevert(abi.encodeWithSelector(ERC3009.ERC3009AuthorizationExpired.selector, validBefore));
        }
        _transferWithAuthorization(auth, signature);

        if (timestamp > validAfter && timestamp < validBefore) {
            assertEq(token.balanceOf(bob), auth.value);
        }
    }

    function testFuzz_RevertWhen_fieldTampered(uint256 field, uint256 newValue, address newTo, bytes32 newNonce)
        public
    {
        Authorization memory auth = _defaultAuthorization();
        bytes memory signature =
            _signBytes(alicePk, _authorizationDigest(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), auth));

        field = bound(field, 0, 2);
        if (field == 0) {
            vm.assume(newValue != auth.value);
            auth.value = newValue;
        } else if (field == 1) {
            vm.assume(newTo != auth.to);
            auth.to = newTo;
        } else {
            vm.assume(newNonce != auth.nonce);
            auth.nonce = newNonce;
        }

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, signature);
    }

    function testFuzz_RevertWhen_arbitrarySignature(bytes32 r, bytes32 s, uint8 v) public {
        Authorization memory auth = _defaultAuthorization();

        vm.expectRevert(ERC3009.ERC3009InvalidSignature.selector);
        _transferWithAuthorization(auth, v, r, s);
    }

    function testFuzz_cancelAuthorization(uint256 privateKey, bytes32 nonce) public {
        (address signer, uint256 key) = _fundedSigner(privateKey);

        token.cancelAuthorization(signer, nonce, _signBytes(key, _cancelDigest(signer, nonce)));

        assertTrue(token.authorizationState(signer, nonce));
        assertEq(token.balanceOf(signer), SIGNER_BALANCE);
    }
}
