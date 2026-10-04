// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title PositionMath
/// @notice Concentrated-liquidity arithmetic for a matched bond: how much token0 must be supplied
///         to pair with a given amount of token1 over a range, and what a token0 balance is worth
///         in token1 terms.
///
/// @dev Both come straight from the V3 curve. A position over [Pa, Pb] with the price P inside it
///      holds
///
///          amount0 = L · (√Pb − √P) / (√P · √Pb)      amount1 = L · (√P − √Pa)
///
///      so pinning `amount1` pins L, and L pins `amount0`:
///
///          L       = amount1 · 2^96 / (√P − √Pa)
///          amount0 = L · (√Pb − √P) · 2^96 / (√P · √Pb)
///
///      For a full-range position this degenerates to `amount0 = amount1 / P`, as it must.
///
///      ROUNDING. BOTH functions round UP, and that is load-bearing rather than stylistic.
///      {token0For} sizes what the protocol makes available to the position manager, so rounding
///      down could leave it a wei short and revert a bond outright.
///
///      {token0ValueInToken1} is subtler, and takes its rounding from the caller because the two
///      legs need opposite directions. The bond splits the minted liquidity as
///
///          credited = liquidity · depositorValue / (depositorValue + protocolValue)
///
///      so understating the PROTOCOL's leg shrinks the denominator, and overstating the
///      DEPOSITOR's leg grows the numerator — both credit a depositor more liquidity than they
///      funded. Hence Ceil for the protocol, Floor for the depositor. Ceil also makes the pair
///      composable: `token0ValueInToken1(token0For(x, …), …, Ceil) >= x` for every price and
///      size, which is the invariant the fairness of the split rests on.
library PositionMath {
    uint256 private constant Q96 = 1 << 96;

    /// @notice token0 required to pair with `amount1` of token1 over [sqrtPaX96, sqrtPbX96].
    /// @dev Reverts unless the price sits strictly inside the range: below it the position wants
    ///      only token0 (so no amount of token1 can be paired) and at or above it the position
    ///      wants only token1 (so the match would be zero and the depositor would silently fund
    ///      the whole position). Both are states a matched bond must refuse, not paper over.
    function token0For(uint256 amount1, uint160 sqrtPX96, uint160 sqrtPaX96, uint160 sqrtPbX96)
        internal
        pure
        returns (uint256 amount0)
    {
        require(sqrtPaX96 < sqrtPbX96, "PositionMath: bad range");
        require(sqrtPX96 > sqrtPaX96 && sqrtPX96 < sqrtPbX96, "PositionMath: price out of range");
        if (amount1 == 0) return 0;

        uint256 liquidity = Math.mulDiv(amount1, Q96, uint256(sqrtPX96) - sqrtPaX96, Math.Rounding.Ceil);
        amount0 = Math.mulDiv(
            Math.mulDiv(liquidity, uint256(sqrtPbX96) - sqrtPX96, sqrtPbX96, Math.Rounding.Ceil),
            Q96,
            sqrtPX96,
            Math.Rounding.Ceil
        );
    }

    /// @notice `amount0` of token0 valued in token1 at the current price.
    /// @param  rounding Caller's choice, and a safety decision rather than a preference. The bond
    ///         splits liquidity as `credited = L · d / (d + p)`, so the depositor's leg `d` must
    ///         round DOWN and the protocol's leg `p` must round UP. Either mistake credits a
    ///         depositor more liquidity than they funded.
    function token0ValueInToken1(uint256 amount0, uint160 sqrtPX96, Math.Rounding rounding)
        internal
        pure
        returns (uint256)
    {
        return Math.mulDiv(Math.mulDiv(amount0, sqrtPX96, Q96, rounding), sqrtPX96, Q96, rounding);
    }
}
