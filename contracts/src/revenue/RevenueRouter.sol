// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IWETH} from "../interfaces/IWETH.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";

/// @notice Contracts that pull WETH deposits from the router.
interface IEthDepositor {
    function depositEth(uint256 amount) external;
}

/// @title RevenueRouter
/// @notice Splits the protocol's ETH revenue (as WETH) between forecasters, veTENAX holders and the treasury
/// (whitepaper section 5.4).
/// @dev The split starts at 40 / 40 / 20 and governance can move it within fixed bounds; shares always sum to 100%.
/// `distribute` is permissionless and sends the whole WETH balance; rounding dust goes to the treasury.
contract RevenueRouter {
    using SafeERC20 for IWETH;

    uint256 public constant BPS = 10_000;
    uint256 public constant MIN_FORECASTERS_BPS = 2500;
    uint256 public constant MAX_FORECASTERS_BPS = 5500;
    uint256 public constant MIN_HOLDERS_BPS = 2500;
    uint256 public constant MAX_HOLDERS_BPS = 5500;
    uint256 public constant MIN_TREASURY_BPS = 500;
    uint256 public constant MAX_TREASURY_BPS = 3000;

    IWETH public immutable weth;
    IEthDepositor public immutable seasonRewards;
    IEthDepositor public immutable feeDistributor;
    address public immutable treasury;
    address public immutable governance;

    uint256 public forecastersBps;
    uint256 public holdersBps;
    uint256 public treasuryBps;

    event SharesUpdated(uint256 forecastersBps, uint256 holdersBps, uint256 treasuryBps);
    event Distributed(uint256 forecasters, uint256 holders, uint256 treasury);

    error ZeroAddress();
    error NotGovernance();
    error InvalidShares();
    error NothingToDistribute();

    constructor(
        IWETH weth_,
        IEthDepositor seasonRewards_,
        IEthDepositor feeDistributor_,
        address treasury_,
        address governance_
    ) {
        if (
            address(weth_) == address(0) || address(seasonRewards_) == address(0)
                || address(feeDistributor_) == address(0) || treasury_ == address(0) || governance_ == address(0)
        ) revert ZeroAddress();
        weth = weth_;
        seasonRewards = seasonRewards_;
        feeDistributor = feeDistributor_;
        treasury = treasury_;
        governance = governance_;
        _setShares(4000, 4000, 2000);
    }

    /// @notice Sets the revenue split, in basis points, within the bounds.
    function setShares(uint256 forecasters, uint256 holders, uint256 treasuryShare) external {
        if (msg.sender != governance) revert NotGovernance();
        _setShares(forecasters, holders, treasuryShare);
    }

    /// @notice Splits the router's whole WETH balance. Anyone can call it.
    function distribute() external {
        uint256 amount = weth.balanceOf(address(this));
        if (amount == 0) revert NothingToDistribute();
        uint256 forecasters = amount * forecastersBps / BPS;
        uint256 holders = amount * holdersBps / BPS;
        uint256 toTreasury = amount - forecasters - holders;
        emit Distributed(forecasters, holders, toTreasury);

        _deposit(seasonRewards, forecasters);
        _deposit(feeDistributor, holders);
        if (toTreasury != 0) weth.safeTransfer(treasury, toTreasury);
    }

    function _deposit(IEthDepositor to, uint256 amount) private {
        if (amount == 0) return;
        weth.forceApprove(address(to), amount);
        to.depositEth(amount);
    }

    function _setShares(uint256 forecasters, uint256 holders, uint256 treasuryShare) private {
        if (
            forecasters < MIN_FORECASTERS_BPS || forecasters > MAX_FORECASTERS_BPS || holders < MIN_HOLDERS_BPS
                || holders > MAX_HOLDERS_BPS || treasuryShare < MIN_TREASURY_BPS || treasuryShare > MAX_TREASURY_BPS
                || forecasters + holders + treasuryShare != BPS
        ) revert InvalidShares();
        forecastersBps = forecasters;
        holdersBps = holders;
        treasuryBps = treasuryShare;
        emit SharesUpdated(forecasters, holders, treasuryShare);
    }
}
