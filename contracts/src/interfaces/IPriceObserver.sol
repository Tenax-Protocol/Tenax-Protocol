// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Time-weighted average tick of the protocol's pool, kept by the launch hook. It only guards buybacks
/// against a manipulated spot price and is never used to value anything.
interface IPriceObserver {
    /// @notice Arithmetic mean of the pool tick over the last `window` seconds.
    function meanTick(uint32 window) external view returns (int24);
}
