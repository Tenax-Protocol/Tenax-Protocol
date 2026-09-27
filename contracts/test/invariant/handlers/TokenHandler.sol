// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TenaxToken} from "../../../src/token/TenaxToken.sol";
import {Test} from "forge-std/Test.sol";

/// @dev Drives random sequences of transfers, burns and signed authorizations among a fixed set of actors,
/// tracking what should be true so the invariant test can compare.
contract TokenHandler is Test {
    TenaxToken public immutable token;

    address[] public actors;
    mapping(address actor => uint256 privateKey) internal keys;

    uint256 public ghostBurned;
    uint256 public ghostAuthorizationsUsed;
    bool public ghostReplaySucceeded;

    uint256 internal nonceCounter;
    bytes32[] internal usedNonces;
    address[] internal usedNonceOwners;

    constructor(TenaxToken token_, address distributor, uint256 actorCount, uint256 fundingPerActor) {
        token = token_;
        for (uint256 i; i < actorCount; ++i) {
            (address actor, uint256 key) = makeAddrAndKey(string.concat("actor-", vm.toString(i)));
            actors.push(actor);
            keys[actor] = key;
            vm.prank(distributor);
            token.transfer(actor, fundingPerActor);
        }
    }

    function actorCount() external view returns (uint256) {
        return actors.length;
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        vm.prank(from);
        token.transfer(to, amount);
    }

    function burn(uint256 seed, uint256 amount) external {
        address actor = _actor(seed);
        amount = bound(amount, 0, token.balanceOf(actor));
        vm.prank(actor);
        token.burn(amount);
        ghostBurned += amount;
    }

    function transferWithAuthorization(uint256 fromSeed, uint256 toSeed, uint256 amount) external {
        address from = _actor(fromSeed);
        address to = _actor(toSeed);
        amount = bound(amount, 0, token.balanceOf(from));
        bytes32 nonce = keccak256(abi.encode("handler-nonce", nonceCounter++));
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), from, to, amount, validAfter, validBefore, nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[from], _digest(structHash));

        token.transferWithAuthorization(from, to, amount, validAfter, validBefore, nonce, v, r, s);
        ghostAuthorizationsUsed++;
        usedNonces.push(nonce);
        usedNonceOwners.push(from);
    }

    /// @dev Tries to reuse an already consumed nonce with a fresh signature; it must always fail.
    function replayAuthorization(uint256 indexSeed, uint256 toSeed) external {
        if (usedNonces.length == 0) return;
        uint256 index = bound(indexSeed, 0, usedNonces.length - 1);
        address from = usedNonceOwners[index];
        address to = _actor(toSeed);
        bytes32 nonce = usedNonces[index];
        uint256 validAfter = block.timestamp - 1;
        uint256 validBefore = block.timestamp + 1 hours;

        bytes32 structHash = keccak256(
            abi.encode(token.TRANSFER_WITH_AUTHORIZATION_TYPEHASH(), from, to, 0, validAfter, validBefore, nonce)
        );
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(keys[from], _digest(structHash));

        try token.transferWithAuthorization(from, to, 0, validAfter, validBefore, nonce, v, r, s) {
            ghostReplaySucceeded = true;
        } catch {}
    }

    function warp(uint256 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 7 days));
    }

    function _actor(uint256 seed) internal view returns (address) {
        return actors[bound(seed, 0, actors.length - 1)];
    }

    function _digest(bytes32 structHash) internal view returns (bytes32) {
        return keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
    }
}
