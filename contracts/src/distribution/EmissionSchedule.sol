// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @notice OP Stack predeploy exposing the latest known Ethereum L1 block.
interface IL1Block {
    function number() external view returns (uint64);
}

/// @title EmissionSchedule
/// @notice Cumulative forecaster emissions as a function of the Ethereum L1 block (whitepaper section 6.2).
/// @dev Emissions are released in epochs of 2,628,000 L1 blocks. Epoch k+1 emits E_k * (1 - r_k), with
/// r = (50%, 40%, 30%, 20%) and a 15% floor afterwards; E_1 sizes the infinite series to the 35M bucket.
/// Within an epoch, emission accrues linearly per block.
///
/// The cumulative amount after k whole epochs comes from a table for k <= 5 and from a closed-form geometric
/// series for the floor epochs, so every query runs in constant time (plus an O(log k) power). Every value
/// rounds down, so the schedule never exceeds 35M, and the accrual inside an epoch is the difference between two
/// consecutive cumulative values, so the curve is monotonic across epoch boundaries.
contract EmissionSchedule {
    /// @notice L1Block predeploy on OP Stack chains.
    IL1Block public constant L1_BLOCK = IL1Block(0x4200000000000000000000000000000000000015);

    /// @notice Forecaster emissions bucket: 35,000,000 TENAX.
    uint256 public constant BUCKET = 35_000_000e18;

    /// @notice Epoch length in L1 blocks, about one year at 12-second blocks.
    uint256 public constant EPOCH_BLOCKS = 2_628_000;

    // Cumulative emission after whole epochs 1 to 5, with E_1 = floor(35M / 3.13) and each later epoch rounded down.
    uint256 private constant CUMULATIVE_1 = 11_182_108_626_198_083_067_092_651;
    uint256 private constant CUMULATIVE_2 = 16_773_162_939_297_124_600_638_976;
    uint256 private constant CUMULATIVE_3 = 20_127_795_527_156_549_520_766_771;
    uint256 private constant CUMULATIVE_4 = 22_476_038_338_658_146_964_856_227;
    uint256 private constant CUMULATIVE_5 = 24_354_632_587_859_424_920_127_792;

    /// @dev Sum of every floor epoch: E_5 * 0.85 / 0.15, rounded down.
    uint256 private constant FLOOR_TAIL = 10_645_367_412_140_575_079_872_201;

    /// @dev 0.85 in 1e36 fixed point; the high precision keeps the power monotonic wherever it matters.
    uint256 private constant FLOOR_RATIO = 0.85e36;
    uint256 private constant ONE = 1e36;

    /// @notice L1 block at which emissions start.
    uint256 public immutable startL1Block;

    constructor(uint256 startL1Block_) {
        startL1Block = startL1Block_;
    }

    /// @notice Emission accrued up to the latest L1 block known on this chain.
    function emitted() external view returns (uint256) {
        return emittedUntil(currentL1Block());
    }

    /// @notice Latest Ethereum L1 block number, read from the L1Block predeploy.
    function currentL1Block() public view returns (uint256) {
        return L1_BLOCK.number();
    }

    /// @notice Cumulative emission up to `l1Block`.
    function emittedUntil(uint256 l1Block) public view returns (uint256) {
        if (l1Block <= startL1Block) return 0;
        uint256 elapsed = l1Block - startL1Block;
        uint256 epochs = elapsed / EPOCH_BLOCKS;
        uint256 done = cumulativeAfter(epochs);
        uint256 current = cumulativeAfter(epochs + 1) - done;
        return done + current * (elapsed % EPOCH_BLOCKS) / EPOCH_BLOCKS;
    }

    /// @notice Cumulative emission after `epochs` whole epochs.
    function cumulativeAfter(uint256 epochs) public pure returns (uint256) {
        if (epochs == 0) return 0;
        if (epochs == 1) return CUMULATIVE_1;
        if (epochs == 2) return CUMULATIVE_2;
        if (epochs == 3) return CUMULATIVE_3;
        if (epochs == 4) return CUMULATIVE_4;
        if (epochs == 5) return CUMULATIVE_5;
        // Floor epochs 6..k emit FLOOR_TAIL * (1 - 0.85^(k-5)). The remainder rounds up, so the sum rounds down.
        uint256 remaining = Math.mulDiv(FLOOR_TAIL, _powUp(FLOOR_RATIO, epochs - 5), ONE, Math.Rounding.Ceil);
        return CUMULATIVE_5 + FLOOR_TAIL - remaining;
    }

    /// @dev base^exponent in 1e36 fixed point, by squaring, rounding every product up.
    function _powUp(uint256 base, uint256 exponent) private pure returns (uint256 result) {
        result = ONE;
        while (exponent != 0) {
            if (exponent & 1 == 1) result = Math.mulDiv(result, base, ONE, Math.Rounding.Ceil);
            exponent >>= 1;
            if (exponent != 0) base = Math.mulDiv(base, base, ONE, Math.Rounding.Ceil);
        }
    }
}
