// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBurnableERC20, VotingEscrow} from "../escrow/VotingEscrow.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @title MerkleAirdrop
/// @notice Community airdrop claimed straight into vote escrow locks (whitepaper section 6.3).
/// @dev Each leaf grants a maximum amount to one account. The fraction received depends on the lock duration the
/// claimer chooses (26, 52 or 104 weeks for 50%, 75% or 100%), and the rest is burned in the same transaction.
/// Claims open once, after the official pool exists, and last 90 days; afterwards anyone can burn what is left.
///
/// Leaves follow the OpenZeppelin standard Merkle tree encoding:
/// `keccak256(bytes.concat(keccak256(abi.encode(account, maxAmount))))`.
contract MerkleAirdrop is ReentrancyGuardTransient {
    using SafeERC20 for IBurnableERC20;

    /// @notice How long claims stay open.
    uint256 public constant CLAIM_PERIOD = 90 days;

    uint256 public constant SHORT_LOCK = 26 weeks;
    uint256 public constant MEDIUM_LOCK = 52 weeks;
    uint256 public constant LONG_LOCK = 104 weeks;

    IBurnableERC20 public immutable token;
    VotingEscrow public immutable escrow;
    bytes32 public immutable merkleRoot;
    address private immutable _opener;

    /// @notice End of the claim period; zero while claims have not opened.
    uint256 public claimDeadline;

    mapping(address account => bool) public claimed;

    event Opened(uint256 deadline);
    event Claimed(address indexed account, uint256 maxAmount, uint256 received, uint256 burned, uint256 lockDuration);
    event UnclaimedBurned(uint256 amount);

    error ZeroAddress();
    error TokenMismatch();
    error NotOpener();
    error AlreadyOpened();
    error NotOpen();
    error ClaimPeriodOver();
    error ClaimPeriodNotOver(uint256 deadline);
    error AlreadyClaimed();
    error InvalidProof();
    error InvalidLockDuration(uint256 duration);

    /// @param opener_ Account allowed to open claims once; the launch script, right after creating the pool.
    constructor(IBurnableERC20 token_, VotingEscrow escrow_, bytes32 merkleRoot_, address opener_) {
        if (address(token_) == address(0) || address(escrow_) == address(0) || opener_ == address(0)) {
            revert ZeroAddress();
        }
        if (address(escrow_.token()) != address(token_)) revert TokenMismatch();
        token = token_;
        escrow = escrow_;
        merkleRoot = merkleRoot_;
        _opener = opener_;
    }

    /// @notice Opens claims for `CLAIM_PERIOD`. Can only happen once.
    function open() external {
        if (msg.sender != _opener) revert NotOpener();
        if (claimDeadline != 0) revert AlreadyOpened();
        uint256 deadline = block.timestamp + CLAIM_PERIOD;
        claimDeadline = deadline;
        emit Opened(deadline);
    }

    /// @notice Claims the caller's allocation into a lock of `lockDuration`, burning the fraction not received.
    /// @dev An expired lock that was not withdrawn blocks the delivery; withdraw it first.
    function claim(uint256 maxAmount, uint256 lockDuration, bytes32[] calldata proof) external nonReentrant {
        uint256 deadline = claimDeadline;
        if (deadline == 0) revert NotOpen();
        if (block.timestamp >= deadline) revert ClaimPeriodOver();
        if (claimed[msg.sender]) revert AlreadyClaimed();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, maxAmount))));
        if (!MerkleProof.verifyCalldata(proof, merkleRoot, leaf)) revert InvalidProof();

        uint256 received = maxAmount * fractionBps(lockDuration) / 10_000;
        uint256 burned = maxAmount - received;
        claimed[msg.sender] = true;
        // No external call precedes this event: MerkleProof is an internal library function.
        // forge-lint: disable-next-line(reentrancy-events)
        emit Claimed(msg.sender, maxAmount, received, burned, lockDuration);

        token.forceApprove(address(escrow), received);
        escrow.createLockFor(msg.sender, received, lockDuration);
        if (burned != 0) token.burn(burned);
    }

    /// @notice Burns every unclaimed token once the claim period is over. Anyone can call it.
    function burnUnclaimed() external {
        uint256 deadline = claimDeadline;
        if (deadline == 0 || block.timestamp < deadline) revert ClaimPeriodNotOver(deadline);
        uint256 amount = token.balanceOf(address(this));
        emit UnclaimedBurned(amount);
        token.burn(amount);
    }

    /// @notice Fraction of the allocation received for each accepted lock duration, in basis points.
    function fractionBps(uint256 lockDuration) public pure returns (uint256) {
        if (lockDuration == SHORT_LOCK) return 5000;
        if (lockDuration == MEDIUM_LOCK) return 7500;
        if (lockDuration == LONG_LOCK) return 10_000;
        revert InvalidLockDuration(lockDuration);
    }
}
