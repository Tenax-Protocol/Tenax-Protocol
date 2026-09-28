// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";

/// @title PoolLauncher
/// @notice Creates the protocol's pool and its liquidity position in a single transaction (whitepaper section 5.1).
/// @dev The launch hook only lets this contract initialize the pool. `launch` initializes it at the launch tick and
/// mints, with every TENAX this contract holds, a position from the maximum TENAX price down to the launch price.
/// The pool starts at the top of that range, so the position holds only TENAX and needs no ETH. The position NFT is
/// minted straight to the liquidity vault, and any rounding leftover is swept there, where fee collection burns it.
contract PoolLauncher {
    using SafeERC20 for IERC20;

    IPoolManager public immutable poolManager;
    IPositionManager public immutable positionManager;
    IERC20 public immutable token;
    address private immutable _owner;

    bool public launched;

    event PoolLaunched(
        bytes32 indexed poolId, uint256 indexed tokenId, int24 launchTick, uint256 tenax, uint128 liquidity
    );

    error ZeroAddress();
    error NotOwner();
    error AlreadyLaunched();
    error TickNotAligned(int24 tick);

    constructor(IPoolManager poolManager_, IPositionManager positionManager_, IERC20 token_) {
        if (
            address(poolManager_) == address(0) || address(positionManager_) == address(0)
                || address(token_) == address(0)
        ) {
            revert ZeroAddress();
        }
        poolManager = poolManager_;
        positionManager = positionManager_;
        token = token_;
        _owner = msg.sender;
    }

    /// @notice Initializes `key` at `launchTick` and mints the protocol position to `vault`. Runs once.
    function launch(PoolKey calldata key, int24 launchTick, address vault) external returns (uint256 tokenId) {
        if (msg.sender != _owner) revert NotOwner();
        if (launched) revert AlreadyLaunched();
        if (vault == address(0)) revert ZeroAddress();
        if (launchTick % key.tickSpacing != 0) revert TickNotAligned(launchTick);
        launched = true;

        // The initial tick is the launch tick itself.
        // forge-lint: disable-next-line(unused-return)
        poolManager.initialize(key, TickMath.getSqrtPriceAtTick(launchTick));

        uint256 amount = token.balanceOf(address(this));
        int24 lower = TickMath.minUsableTick(key.tickSpacing);
        uint128 liquidity = LiquidityAmounts.getLiquidityForAmount1(
            TickMath.getSqrtPriceAtTick(lower), TickMath.getSqrtPriceAtTick(launchTick), amount
        );
        tokenId = positionManager.nextTokenId();
        token.safeTransfer(address(positionManager), amount);

        // Mint, pay the TENAX owed from the position manager's own balance, and sweep what is left to the vault.
        bytes memory actions = abi.encodePacked(ACTION_MINT_POSITION, ACTION_SETTLE, ACTION_SWEEP);
        bytes[] memory params = new bytes[](3);
        params[0] = abi.encode(key, lower, launchTick, uint256(liquidity), ZERO, _toUint128(amount), vault, bytes(""));
        params[1] = abi.encode(key.currency1, uint256(0), false);
        params[2] = abi.encode(key.currency1, vault);
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        // Runs once, called by the owner; the only external calls go to Uniswap and the token.
        // forge-lint: disable-next-line(reentrancy-events)
        emit PoolLaunched(PoolId.unwrap(key.toId()), tokenId, launchTick, amount, liquidity);
    }

    // Uniswap's action codes are single bytes.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint8 private constant ACTION_MINT_POSITION = uint8(Actions.MINT_POSITION);
    // forge-lint: disable-next-line(unsafe-typecast)
    uint8 private constant ACTION_SETTLE = uint8(Actions.SETTLE);
    // forge-lint: disable-next-line(unsafe-typecast)
    uint8 private constant ACTION_SWEEP = uint8(Actions.SWEEP);
    uint128 private constant ZERO = 0;

    function _toUint128(uint256 value) private pure returns (uint128) {
        // The whole supply is 1e26, far below 2^128.
        // forge-lint: disable-next-line(unsafe-typecast)
        return uint128(value);
    }
}
