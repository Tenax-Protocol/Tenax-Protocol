// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Shared setup and EIP-712 signing helpers for token tests.
abstract contract TokenTestBase is Test {
    bytes32 internal constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    struct Authorization {
        address from;
        address to;
        uint256 value;
        uint256 validAfter;
        uint256 validBefore;
        bytes32 nonce;
    }

    TenaxToken internal token;
    address internal distributor = makeAddr("distributor");
    address internal alice;
    uint256 internal alicePk;
    address internal bob = makeAddr("bob");
    address internal relayer = makeAddr("relayer");

    uint256 internal constant ALICE_BALANCE = 1_000_000e18;
    uint256 internal constant NOW = 1_800_000_000;

    function setUp() public virtual {
        (alice, alicePk) = makeAddrAndKey("alice");
        token = new TenaxToken(distributor);
        vm.prank(distributor);
        token.transfer(alice, ALICE_BALANCE);
        vm.warp(NOW);
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }

    function _authorizationDigest(bytes32 typeHash, Authorization memory auth) internal view returns (bytes32) {
        return _digest(
            keccak256(
                abi.encode(typeHash, auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce)
            )
        );
    }

    function _cancelDigest(address authorizer, bytes32 nonce) internal view returns (bytes32) {
        return _digest(keccak256(abi.encode(token.CANCEL_AUTHORIZATION_TYPEHASH(), authorizer, nonce)));
    }

    function _permitDigest(address owner, address spender, uint256 value, uint256 nonce, uint256 deadline)
        internal
        view
        returns (bytes32)
    {
        return _digest(keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonce, deadline)));
    }

    function _signBytes(uint256 privateKey, bytes32 digest) internal pure returns (bytes memory) {
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(privateKey, digest);
        return abi.encodePacked(r, s, v);
    }

    /// @dev A valid authorization from alice to bob, usable now.
    function _defaultAuthorization() internal view returns (Authorization memory) {
        return Authorization({
            from: alice,
            to: bob,
            value: 100e18,
            validAfter: block.timestamp - 1,
            validBefore: block.timestamp + 1 hours,
            nonce: keccak256("nonce-1")
        });
    }

    function _transferWithAuthorization(Authorization memory auth, uint8 v, bytes32 r, bytes32 s) internal {
        token.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, v, r, s
        );
    }

    function _transferWithAuthorization(Authorization memory auth, bytes memory signature) internal {
        token.transferWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, signature
        );
    }

    function _receiveWithAuthorization(Authorization memory auth, bytes memory signature) internal {
        token.receiveWithAuthorization(
            auth.from, auth.to, auth.value, auth.validAfter, auth.validBefore, auth.nonce, signature
        );
    }
}
