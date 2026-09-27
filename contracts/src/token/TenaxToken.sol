// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC3009} from "./ERC3009.sol";
import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {ERC20Burnable} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Burnable.sol";
import {ERC20Permit} from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";

/// @title TenaxToken
/// @notice The Tenax Protocol token (TENAX).
/// @dev Fixed supply minted once in the constructor. There is no owner, no privileged function and no mint
/// function: after deployment, supply can only decrease through burning. Approvals by signature follow
/// EIP-2612 and transfers by signature follow EIP-3009, both under the EIP-712 domain
/// `name = "Tenax Protocol"`, `version = "1"`. Voting power comes from the vote escrow, not from this token.
contract TenaxToken is ERC20, ERC20Permit, ERC20Burnable, ERC3009 {
    /// @notice Total supply minted at deployment: 100,000,000 TENAX.
    uint256 public constant INITIAL_SUPPLY = 100_000_000e18;

    /// @param recipient Receives the entire supply; the deployment script distributes it to the protocol contracts.
    constructor(address recipient) ERC20("Tenax Protocol", "TENAX") ERC20Permit("Tenax Protocol") {
        _mint(recipient, INITIAL_SUPPLY);
    }
}
