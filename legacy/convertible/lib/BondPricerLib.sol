// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

library BondPricerLib {
    function getAssetAmountFromBond(uint256 bondAmountUsdc1e6, uint160 strikeSqrtAssetUsdc)
        internal
        pure
        returns (uint256 assetAmount)
    {
        // The raw price is defined as (amount of token1 base units) / (amount of token0 base units).
        // price_raw = USDC_base_units / Asset_base_units
        // price_raw = (strikeSqrtAssetUsdc^2) / (2^192)
        //
        // We want to calculate the amount of Asset from a given amount of USDC.
        // Amount_Asset_base_units = Amount_USDC_base_units / price_raw
        //
        // To avoid precision loss from dividing by a small price_raw, we rearrange the formula:
        // Amount_Asset_base_units = (Amount_USDC_base_units * 2^192) / (strikeSqrtAssetUsdc^2)

        if (bondAmountUsdc1e6 == 0) {
            return 0;
        }

        uint256 strikePriceX96 = uint256(strikeSqrtAssetUsdc);

        // Calculate numerator: bondAmountUsdc1e6 * 2^192
        // 2^192 = 1 << 192
        uint256 numerator = bondAmountUsdc1e6 << 192;

        // Calculate denominator: strikePriceX96^2
        uint256 denominator = strikePriceX96 * strikePriceX96;

        // assetAmount will be in the base units of the Asset token (18 decimals)
        assetAmount = numerator / denominator;
    }
}
