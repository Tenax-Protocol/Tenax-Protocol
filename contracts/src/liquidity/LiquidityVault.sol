// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IBurnableERC20} from "../escrow/VotingEscrow.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {RevenueRouter} from "../revenue/RevenueRouter.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC721} from "@openzeppelin/contracts/token/ERC721/IERC721.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";
import {Actions} from "@uniswap/v4-periphery/src/libraries/Actions.sol";

/// @title LiquidityVault
/// @notice Permanent owner of the protocol's Uniswap v4 position (whitepaper section 5.2).
/// @dev The contract has no function that removes liquidity or moves the position: the only call it makes to the
/// position manager decreases liquidity by zero, which collects the fees. At most once every 24 hours, anyone can
/// collect them: ETH fees are wrapped and sent to the revenue router, which distributes them in the same call, and
/// TENAX fees are burned.
contract LiquidityVault is ReentrancyGuardTransient {
    using SafeERC20 for IWETH;

    uint256 public constant COLLECT_INTERVAL = 24 hours;

    // Uniswap's action codes are single bytes (0x01 and 0x11), encoded as such in the action list.
    // forge-lint: disable-next-line(unsafe-typecast)
    uint8 private constant ACTION_DECREASE_LIQUIDITY = uint8(Actions.DECREASE_LIQUIDITY);
    // forge-lint: disable-next-line(unsafe-typecast)
    uint8 private constant ACTION_TAKE_PAIR = uint8(Actions.TAKE_PAIR);
    uint128 private constant ZERO_AMOUNT = 0;

    IPositionManager public immutable positionManager;
    address public immutable poolManager;
    IBurnableERC20 public immutable token;
    IWETH public immutable weth;
    RevenueRouter public immutable router;
    address private immutable _initializer;

    /// @notice The protocol position; zero until the launch hands it over.
    uint256 public tokenId;

    uint256 public lastCollect;
    uint256 public totalEthCollected;
    uint256 public totalTenaxBurned;

    event PositionRegistered(uint256 indexed tokenId);
    event FeesCollected(uint256 eth, uint256 tenaxBurned);

    error ZeroAddress();
    error TokenMismatch();
    error NotInitializer();
    error AlreadyInitialized();
    error NotOwnedByVault();
    error WrongPool();
    error NoPosition();
    error TooSoon(uint256 nextCollect);
    error UnexpectedEth();

    constructor(IPositionManager positionManager_, IBurnableERC20 token_, IWETH weth_, RevenueRouter router_) {
        if (
            address(positionManager_) == address(0) || address(token_) == address(0) || address(weth_) == address(0)
                || address(router_) == address(0)
        ) revert ZeroAddress();
        if (address(router_.weth()) != address(weth_)) revert TokenMismatch();
        positionManager = positionManager_;
        poolManager = address(positionManager_.poolManager());
        token = token_;
        weth = weth_;
        router = router_;
        _initializer = msg.sender;
    }

    /// @notice Native ETH only arrives from the pool manager, as collected fees.
    receive() external payable {
        if (msg.sender != poolManager) revert UnexpectedEth();
    }

    /// @notice Registers, once, the position minted to this vault at launch.
    /// @dev The position must already belong to the vault and sit in a native ETH / TENAX pool.
    function initialize(uint256 tokenId_) external {
        if (msg.sender != _initializer) revert NotInitializer();
        if (tokenId != 0) revert AlreadyInitialized();
        if (IERC721(address(positionManager)).ownerOf(tokenId_) != address(this)) revert NotOwnedByVault();
        // Only the pool matters here; the packed position info is not needed.
        // forge-lint: disable-next-line(unused-return)
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(tokenId_);
        if (!key.currency0.isAddressZero() || Currency.unwrap(key.currency1) != address(token)) revert WrongPool();
        tokenId = tokenId_;
        emit PositionRegistered(tokenId_);
    }

    /// @notice Collects the position's fees: ETH goes to revenue, TENAX is burned. Anyone can call it, at most once
    /// every 24 hours.
    function collectFees() external nonReentrant {
        uint256 id = tokenId;
        if (id == 0) revert NoPosition();
        uint256 nextCollect = lastCollect + COLLECT_INTERVAL;
        if (lastCollect != 0 && block.timestamp < nextCollect) revert TooSoon(nextCollect);
        lastCollect = block.timestamp;

        // forge-lint: disable-next-line(unused-return)
        (PoolKey memory key,) = positionManager.getPoolAndPositionInfo(id);
        // Decreasing liquidity by zero collects the fees without touching the position; minimums are zero too.
        bytes memory actions = abi.encodePacked(ACTION_DECREASE_LIQUIDITY, ACTION_TAKE_PAIR);
        bytes[] memory params = new bytes[](2);
        params[0] = abi.encode(id, uint256(0), ZERO_AMOUNT, ZERO_AMOUNT, bytes(""));
        params[1] = abi.encode(key.currency0, key.currency1, address(this));
        positionManager.modifyLiquidities(abi.encode(actions, params), block.timestamp);

        uint256 eth = address(this).balance;
        uint256 tenax = token.balanceOf(address(this));
        totalEthCollected += eth;
        totalTenaxBurned += tenax;
        // The amounts are only known after the position manager call; it is Uniswap's immutable contract.
        // forge-lint: disable-next-line(reentrancy-events)
        emit FeesCollected(eth, tenax);

        if (eth != 0) {
            weth.deposit{value: eth}();
            weth.safeTransfer(address(router), eth);
            router.distribute();
        }
        if (tenax != 0) token.burn(tenax);
    }

    /// @notice Current liquidity of the protocol position; it can never decrease.
    function positionLiquidity() external view returns (uint128) {
        uint256 id = tokenId;
        return id == 0 ? 0 : positionManager.getPositionLiquidity(id);
    }
}
