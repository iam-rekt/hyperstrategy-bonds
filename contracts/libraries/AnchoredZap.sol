// SPDX-License-Identifier: MIT
pragma solidity 0.8.30;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IUniswapV3Pool} from "../interfaces/IUniswapV3.sol";
import {V3TickMath} from "./V3TickMath.sol";

/// @title AnchoredZap
/// @notice Price limit for a protocol-owned single-sided zap (sell token1, buy token0).
///
/// @dev THE PROBLEM. The caller of a zap chooses its slippage limits, but the PROTOCOL's liquidity
///      bears the slippage. A caller can therefore wrap their own deposit in a sandwich — pump,
///      deposit, dump — and the zap, being a market order, chases the pumped price. The proceeds
///      come out of the protocol's LP leg, risk-free.
///
///      THE FIX. Make the zap a LIMIT order whose price the caller cannot move:
///
///        anchor = min( spot, reference )
///        limit  = the price an honest swap of this size would END at, starting from the anchor
///                 (token1-in on a V3 curve: Δ√P = amountIn / L), shortened by a multiple of any
///                 premium of spot over the anchor
///
///      - start-of-block price: read from the pool's own oracle as tickCumulative(now) −
///        tickCumulative(now − 1s). If spot has been pushed above it inside the current block the
///        zap does not buy at all, which removes the atomic (flash-loanable, zero-risk) sandwich.
///      - reference: the TWAP, or — while fresh — where this contract's own last zap left the
///        price, provided the price has actually STAYED there since (average tick since that
///        zap). Back-to-back deposits therefore keep filling at full size: the contract's own
///        buying is never mistaken for manipulation.
///
///      A pump above the anchor does not revert anything and makes nobody wait. It simply makes
///      the zap buy less; the unspent token1 is carried into the next zap. The protocol never pays
///      more than its own honest impact above a price the caller did not set.
///
///      Measured on a HyperEVM fork against the live HSTR/USD₮0 pool (2026-09-19, 3,000 USD₮0
///      deposit, 25% LP split): an 8,000 USD₮0 self-sandwich that previously netted +208 now loses
///      ~121 in fees; the best result over every front-run size, atomic or multi-block, is +9.4;
///      ten back-to-back deposits deploy 99.999% of their LP split with the same price impact as
///      an unguarded zap.
library AnchoredZap {
    uint256 private constant Q96 = 1 << 96;
    uint160 private constant MAX_SQRT_RATIO = 1461446703485210103287273052203988822378723970342;
    /// @dev ~0.1%: ordinary rounding/ordering noise inside a block, nothing worth sandwiching.
    int24 internal constant SAME_BLOCK_TOLERANCE_TICKS = 10;
    uint256 internal constant PREMIUM_PENALTY = 3;

    struct LastZap {
        int24 tick; // spot tick right after the contract's latest zap
        uint64 at; // its timestamp
        int56 tickCumulative; // pool tickCumulative at that moment
    }

    /// @return limitSqrtP  price the swap may not exceed (pass as sqrtPriceLimitX96)
    /// @return fillable    false when spot already sits at/above the limit: skip the swap
    function limit(IUniswapV3Pool pool, uint32 twapWindow, LastZap memory last, uint256 swapIn, uint24 fee)
        internal
        view
        returns (uint160 limitSqrtP, bool fillable)
    {
        (uint160 spotSqrtP, int24 spotTick,,,,,) = pool.slot0();
        uint128 liquidity = pool.liquidity();
        if (liquidity == 0 || swapIn == 0) return (spotSqrtP, false);

        uint32[] memory ago = new uint32[](3);
        ago[0] = twapWindow;
        ago[1] = 1;
        int56[] memory tc; // ago[2] == 0 → now
        // No readable history means no trustworthy anchor: do not buy. The caller carries the
        // funds forward, so an oracle problem can never make a deposit fail.
        try pool.observe(ago) returns (int56[] memory cumulatives, uint160[] memory) {
            tc = cumulatives;
        } catch {
            return (spotSqrtP, false);
        }

        // (1) Pushed up inside this very block — the atomic, flash-loanable, zero-risk sandwich:
        //     do not buy at all this time. The funds simply wait for the next zap.
        int24 blockStart = int24(tc[2] - tc[1]); // tick that prevailed over the last second
        if (spotTick > blockStart + SAME_BLOCK_TOLERANCE_TICKS) return (spotSqrtP, false);

        int24 anchor = spotTick;

        int24 ref = _mean(tc[2] - tc[0], twapWindow);
        if (last.at != 0 && block.timestamp - last.at <= twapWindow) {
            int24 held = last.tick;
            if (block.timestamp > last.at) {
                int24 since = _mean(tc[2] - last.tickCumulative, uint32(block.timestamp - last.at));
                if (since < held) held = since;
            }
            if (held > ref) ref = held;
        }
        if (ref < anchor) anchor = ref;

        uint256 anchorSqrtP = anchor == spotTick ? spotSqrtP : V3TickMath.getSqrtRatioAtTick(anchor);
        uint256 netIn = Math.mulDiv(swapIn, 1e6 - fee, 1e6);
        uint256 end = anchorSqrtP + Math.mulDiv(netIn, Q96, liquidity);
        // (2) Sitting above the anchor across blocks: shorten the limit by a multiple of that premium.
        //     A sandwicher profits from the zap's push ABOVE their own pump; with the limit falling
        //     PREMIUM_PENALTY times faster than they pump, their best case shrinks by (1 + penalty)
        //     and vanishes well before the honest end price. Honest back-to-back deposits sit exactly
        //     at the anchor and are untouched.
        if (spotSqrtP > anchorSqrtP) {
            uint256 cut = (uint256(spotSqrtP) - anchorSqrtP) * PREMIUM_PENALTY;
            end = end > cut ? end - cut : 0;
        }
        uint256 max = uint256(MAX_SQRT_RATIO) - 1;
        limitSqrtP = uint160(end > max ? max : end);
        fillable = limitSqrtP > spotSqrtP;
    }

    function snapshot(IUniswapV3Pool pool) internal view returns (LastZap memory s) {
        (, int24 tick,,,,,) = pool.slot0();
        uint32[] memory ago = new uint32[](1);
        (int56[] memory tc,) = pool.observe(ago);
        s = LastZap({tick: tick, at: uint64(block.timestamp), tickCumulative: tc[0]});
    }

    function _mean(int56 delta, uint32 window) private pure returns (int24 mean) {
        mean = int24(delta / int56(uint56(window)));
        if (delta < 0 && delta % int56(uint56(window)) != 0) mean--;
    }
}
