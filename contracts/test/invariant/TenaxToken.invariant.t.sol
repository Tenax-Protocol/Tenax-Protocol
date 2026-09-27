// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {TenaxToken} from "../../src/token/TenaxToken.sol";
import {TokenHandler} from "./handlers/TokenHandler.sol";
import {Test} from "forge-std/Test.sol";

contract TenaxTokenInvariantTest is Test {
    TenaxToken internal token;
    TokenHandler internal handler;
    address internal distributor = makeAddr("distributor");

    function setUp() public {
        vm.warp(1_800_000_000);
        token = new TenaxToken(distributor);
        handler = new TokenHandler(token, distributor, 5, 1_000_000e18);
        targetContract(address(handler));
    }

    /// @dev Whitepaper invariant: TENAX total supply never increases after deployment.
    function invariant_supplyNeverIncreases() public view {
        assertLe(token.totalSupply(), token.INITIAL_SUPPLY());
    }

    /// @dev Every token that left the supply was burned, and nothing else changed it.
    function invariant_supplyEqualsInitialMinusBurned() public view {
        assertEq(token.totalSupply(), token.INITIAL_SUPPLY() - handler.ghostBurned());
    }

    /// @dev Transfers, burns and authorizations never create or lose tokens.
    function invariant_balancesSumToSupply() public view {
        uint256 sum = token.balanceOf(distributor);
        for (uint256 i; i < handler.actorCount(); ++i) {
            sum += token.balanceOf(handler.actors(i));
        }
        assertEq(sum, token.totalSupply());
    }

    /// @dev A used authorization nonce can never be executed again.
    function invariant_usedNonceCannotBeReplayed() public view {
        assertFalse(handler.ghostReplaySucceeded());
    }
}
