// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title ZapMath
/// @notice Single-sided zap sizing for a full-range Uniswap-V3 position: given `amount1` of
///         token1 (USD₮0) and the pool's active price and liquidity, how much of it to sell for
///         token0 (HSTR) so the remainder pairs into a full-range position with minimal residue.
///
/// @dev The original repo zapped into a Uniswap-V2 pair, where the optimal swap has an exact
///      closed form on the constant-product reserves. This is the V3 analogue for a FULL-RANGE
///      position: inside the current tick a V3 pool is constant-product on its virtual reserves
///      (X, Y) = (L·2^96/√P, L·√P/2^96), so the same algebra applies with R = Y.
///
///      Selling `s` of token1 with fee factor g = (1e6−f)/1e6 yields `out = g·s·X/(Y+g·s)`, and
///      pairing the remainder at the post-swap price requires (a−s)/out = (R+s)/(X−out). The X
///      terms cancel (full range pairs purely on price), leaving
///
///          s = ( √(R·(R·(D+N)² + 4·N·D·a)) − R·(D+N) ) / (2N),   N = 1e6−f, D = 1e6.
///
///      At f = 0 this reduces to `√(R²+Ra) − R ≈ a/2` — "sell half" — as it must.
///
///      ACCURACY. Exact only while the swap stays inside the current tick. A swap that crosses
///      initialised ticks executes worse than the model predicts, so on a thin pool the estimate
///      skews slightly high and leaves a little residue. That is safe by construction at the call
///      site: the caller adds liquidity with whatever the swap actually returned and refunds both
///      residues to the depositor, so a bad estimate costs dust, never principal.
library ZapMath {
    /// @dev Bounds the reserve/input magnitudes so the discriminant cannot exceed 2^256 and trip
    ///      a bare arithmetic panic. Unreachable for any real pool: R hitting 1e32 on a 6-dec
    ///      quote asset would mean a pool holding 1e26 units of it.
    uint256 internal constant MAX_TERM = 1e32;

    /// @notice token1 to sell for token0 before adding full-range liquidity.
    /// @param amount1      token1 (USD₮0) available to deploy.
    /// @param liquidity    Pool liquidity active at the current tick (`pool.liquidity()`).
    /// @param sqrtPriceX96 Current pool price, Q64.96.
    /// @param fee          Pool fee in hundredths of a bip (1e4 == 1%).
    /// @return swapIn      token1 to sell. Never exceeds `amount1`.
    function optimalSwapIn(uint256 amount1, uint128 liquidity, uint160 sqrtPriceX96, uint24 fee)
        internal
        pure
        returns (uint256 swapIn)
    {
        require(fee < 1e6, "ZapMath: bad fee");
        if (amount1 == 0 || liquidity == 0) return 0;

        uint256 R = Math.mulDiv(uint256(liquidity), sqrtPriceX96, 1 << 96); // virtual token1 reserve
        if (R == 0) return 0;
        require(R <= MAX_TERM && amount1 <= MAX_TERM, "ZapMath: out of domain");

        uint256 N = uint256(1e6) - fee;
        uint256 D = 1e6;
        uint256 sum = D + N; // (D+N)

        // inner = R·(D+N)² + 4·N·D·a
        uint256 inner = R * (sum * sum) + 4 * N * D * amount1;
        uint256 root = Math.sqrt(R * inner);
        uint256 num = root > R * sum ? root - R * sum : 0;
        swapIn = num / (2 * N);

        if (swapIn > amount1) swapIn = amount1;
    }
}
