// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

/// @dev Minimal router for tests: exact-input swaps in a native ETH / token pool, paid by the caller.
contract V4Swapper is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager manager_) {
        manager = manager_;
    }

    /// @dev Buys the token with all the ETH sent. Returns the tokens received.
    function buy(PoolKey calldata key) external payable returns (uint256) {
        return abi.decode(manager.unlock(abi.encode(key, true, msg.value, msg.sender)), (uint256));
    }

    /// @dev Sells `amount` of the token, pulled from the caller. Returns the ETH received.
    function sell(PoolKey calldata key, uint256 amount) external returns (uint256) {
        return abi.decode(manager.unlock(abi.encode(key, false, amount, msg.sender)), (uint256));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "only manager");
        (PoolKey memory key, bool zeroForOne, uint256 amountIn, address payer) =
            abi.decode(data, (PoolKey, bool, uint256, address));
        BalanceDelta delta = manager.swap(
            key,
            IPoolManager.SwapParams({
                zeroForOne: zeroForOne,
                amountSpecified: -int256(amountIn),
                sqrtPriceLimitX96: zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1
            }),
            ""
        );
        (Currency input, Currency output) = zeroForOne ? (key.currency0, key.currency1) : (key.currency1, key.currency0);
        int128 inputDelta = zeroForOne ? delta.amount0() : delta.amount1();
        int128 outputDelta = zeroForOne ? delta.amount1() : delta.amount0();
        uint256 paid = uint256(uint128(-inputDelta));
        uint256 received = uint256(uint128(outputDelta));

        if (input.isAddressZero()) {
            manager.settle{value: paid}();
            if (amountIn > paid) payable(payer).transfer(amountIn - paid);
        } else {
            manager.sync(input);
            IERC20(Currency.unwrap(input)).transferFrom(payer, address(manager), paid);
            manager.settle();
        }
        manager.take(output, payer, received);
        return abi.encode(received);
    }

    receive() external payable {}
}
