// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {EIP712} from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import {SignatureChecker} from "@openzeppelin/contracts/utils/cryptography/SignatureChecker.sol";

/// @title ERC3009
/// @notice Transfers authorized by signature, as specified by EIP-3009.
/// @dev Authorizations use random 32-byte nonces, independent from EIP-2612 permit nonces, so any number
/// of authorizations can be outstanding and used in any order. Signatures are checked with OpenZeppelin's
/// SignatureChecker, which accepts both EOA signatures and ERC-1271 contract wallets. Every function has a
/// `(v, r, s)` form, as in the EIP, and a `bytes signature` form for contract wallets.
/// The inheriting contract must initialize the EIP712 domain (for example through ERC20Permit).
abstract contract ERC3009 is ERC20, EIP712 {
    /// @notice EIP-712 type hash of a TransferWithAuthorization message.
    bytes32 public constant TRANSFER_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "TransferWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @notice EIP-712 type hash of a ReceiveWithAuthorization message.
    bytes32 public constant RECEIVE_WITH_AUTHORIZATION_TYPEHASH = keccak256(
        "ReceiveWithAuthorization(address from,address to,uint256 value,uint256 validAfter,uint256 validBefore,bytes32 nonce)"
    );

    /// @notice EIP-712 type hash of a CancelAuthorization message.
    bytes32 public constant CANCEL_AUTHORIZATION_TYPEHASH =
        keccak256("CancelAuthorization(address authorizer,bytes32 nonce)");

    mapping(address authorizer => mapping(bytes32 nonce => bool used)) private _authorizationStates;

    /// @notice Emitted when an authorization is used for a transfer.
    event AuthorizationUsed(address indexed authorizer, bytes32 indexed nonce);

    /// @notice Emitted when an authorization is canceled before use.
    event AuthorizationCanceled(address indexed authorizer, bytes32 indexed nonce);

    /// @notice The authorization cannot be used before `validAfter`.
    error ERC3009AuthorizationNotYetValid(uint256 validAfter);

    /// @notice The authorization cannot be used at or after `validBefore`.
    error ERC3009AuthorizationExpired(uint256 validBefore);

    /// @notice The nonce was already used or canceled.
    error ERC3009AuthorizationUsedOrCanceled(address authorizer, bytes32 nonce);

    /// @notice The signature does not match the authorizer.
    error ERC3009InvalidSignature();

    /// @notice `receiveWithAuthorization` must be called by the payee.
    error ERC3009CallerMustBePayee(address caller, address payee);

    /// @notice Returns whether `nonce` was already used or canceled by `authorizer`.
    function authorizationState(address authorizer, bytes32 nonce) external view returns (bool) {
        return _authorizationStates[authorizer][nonce];
    }

    /// @notice Executes a transfer authorized by `from`'s signature. Anyone can submit it.
    /// @param from Payer, who signed the authorization.
    /// @param to Payee.
    /// @param value Amount to transfer.
    /// @param validAfter The authorization is valid only after this timestamp.
    /// @param validBefore The authorization is valid only before this timestamp.
    /// @param nonce Unique random nonce chosen by the payer.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH,
            from,
            to,
            value,
            validAfter,
            validBefore,
            nonce,
            abi.encodePacked(r, s, v)
        );
    }

    /// @notice Same as the `(v, r, s)` form, accepting any signature format, including ERC-1271.
    function transferWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        _transferWithAuthorization(
            TRANSFER_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    /// @notice Executes a transfer authorized by `from`'s signature. Only the payee can submit it, which
    /// prevents front-running when the payee is a contract that acts on the received tokens.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        uint8 v,
        bytes32 r,
        bytes32 s
    ) external {
        _receiveWithAuthorization(from, to, value, validAfter, validBefore, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice Same as the `(v, r, s)` form, accepting any signature format, including ERC-1271.
    function receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) external {
        _receiveWithAuthorization(from, to, value, validAfter, validBefore, nonce, signature);
    }

    /// @notice Cancels an unused authorization, so it can never be executed.
    function cancelAuthorization(address authorizer, bytes32 nonce, uint8 v, bytes32 r, bytes32 s) external {
        _cancelAuthorization(authorizer, nonce, abi.encodePacked(r, s, v));
    }

    /// @notice Same as the `(v, r, s)` form, accepting any signature format, including ERC-1271.
    function cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) external {
        _cancelAuthorization(authorizer, nonce, signature);
    }

    function _receiveWithAuthorization(
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        if (to != msg.sender) revert ERC3009CallerMustBePayee(msg.sender, to);
        _transferWithAuthorization(
            RECEIVE_WITH_AUTHORIZATION_TYPEHASH, from, to, value, validAfter, validBefore, nonce, signature
        );
    }

    function _transferWithAuthorization(
        bytes32 typeHash,
        address from,
        address to,
        uint256 value,
        uint256 validAfter,
        uint256 validBefore,
        bytes32 nonce,
        bytes memory signature
    ) private {
        // Validity windows are part of EIP-3009; a few seconds of timestamp drift has no meaningful effect.
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp <= validAfter) revert ERC3009AuthorizationNotYetValid(validAfter);
        // forge-lint: disable-next-line(block-timestamp)
        if (block.timestamp >= validBefore) revert ERC3009AuthorizationExpired(validBefore);

        // Effects before the signature check: an ERC-1271 wallet is called through a staticcall, and an
        // invalid signature reverts the whole transaction, including these writes.
        _useAuthorization(from, nonce);
        emit AuthorizationUsed(from, nonce);

        bytes32 structHash = keccak256(abi.encode(typeHash, from, to, value, validAfter, validBefore, nonce));
        _requireValidSignature(from, structHash, signature);

        _transfer(from, to, value);
    }

    function _cancelAuthorization(address authorizer, bytes32 nonce, bytes memory signature) private {
        _useAuthorization(authorizer, nonce);
        emit AuthorizationCanceled(authorizer, nonce);

        bytes32 structHash = keccak256(abi.encode(CANCEL_AUTHORIZATION_TYPEHASH, authorizer, nonce));
        _requireValidSignature(authorizer, structHash, signature);
    }

    function _useAuthorization(address authorizer, bytes32 nonce) private {
        if (_authorizationStates[authorizer][nonce]) revert ERC3009AuthorizationUsedOrCanceled(authorizer, nonce);
        _authorizationStates[authorizer][nonce] = true;
    }

    function _requireValidSignature(address signer, bytes32 structHash, bytes memory signature) private view {
        if (!SignatureChecker.isValidSignatureNow(signer, _hashTypedDataV4(structHash), signature)) {
            revert ERC3009InvalidSignature();
        }
    }
}
