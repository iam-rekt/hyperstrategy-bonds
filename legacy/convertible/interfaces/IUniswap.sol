// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.28;

interface IUniswapV3Pool {
    function observe(uint32[] memory secondsAgos)
        external
        view
        returns (int56[] memory tickCumulatives, uint160[] memory secondsPerLiquidityCumulativeX128s);
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            uint8 feeProtocol,
            bool unlocked
        );
    function tickSpacing() external view returns (int24);
    function token0() external view returns (address);
    function token1() external view returns (address);
    function initialize(uint160 sqrtPriceX96) external;
}

interface IUniswapV3Factory {
    // UPDATED: createPool now takes tickSpacing and sqrtPriceX96
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool);

    // UPDATED: Replaced enableFeeAmount with enableTickSpacing
    function enableTickSpacing(int24 tickSpacing, uint24 fee) external;

    // REMOVED: feeAmountTickSpacing is no longer a function. It's a public mapping `tickSpacingToFee` in the implementation.

    // UPDATED: getPool now takes tickSpacing instead of fee
    function getPool(address, address, int24) external view returns (address);

    function owner() external view returns (address);
    // REMOVED: parameters() function does not exist in Kittenswap's CLFactory
    function setOwner(address _owner) external;
}

/// @title Router token swapping functionality
/// @notice Functions for swapping tokens via Uniswap V3
interface IUniswapSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        // UPDATED: fee changed to tickSpacing
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactInputSingleParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);

    struct ExactInputParams {
        // NOTE: The path encoding now uses tickSpacing instead of fee. e.g., (tokenIn, tickSpacing, tokenOut, ... )
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
    }

    /// @notice Swaps `amountIn` of one token for as much as possible of another along the specified path
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactInputParams` in calldata
    /// @return amountOut The amount of the received token
    function exactInput(ExactInputParams calldata params) external payable returns (uint256 amountOut);

    struct ExactOutputSingleParams {
        address tokenIn;
        address tokenOut;
        // UPDATED: fee changed to tickSpacing
        int24 tickSpacing;
        address recipient;
        uint256 amountOut;
        uint256 amountInMaximum;
        uint160 sqrtPriceLimitX96;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another token
    /// @param params The parameters necessary for the swap, encoded as `ExactOutputSingleParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutputSingle(ExactOutputSingleParams calldata params) external payable returns (uint256 amountIn);

    struct ExactOutputParams {
        // NOTE: The path encoding now uses tickSpacing instead of fee. e.g., (tokenOut, tickSpacing, tokenIn, ... )
        bytes path;
        address recipient;
        uint256 deadline;
        uint256 amountOut;
        uint256 amountInMaximum;
    }

    /// @notice Swaps as little as possible of one token for `amountOut` of another along the specified path (reversed)
    /// @param params The parameters necessary for the multi-hop swap, encoded as `ExactOutputParams` in calldata
    /// @return amountIn The amount of the input token
    function exactOutput(ExactOutputParams calldata params) external payable returns (uint256 amountIn);

    /// @notice Unwraps the contract's WETH9 balance and sends it to recipient as ETH.
    /// @dev The amountMinimum parameter prevents malicious contracts from stealing WETH9 from users.
    /// @param amountMinimum The minimum amount of WETH9 to unwrap
    /// @param recipient The address receiving ETH
    function unwrapWETH9(uint256 amountMinimum, address recipient) external payable;

    /// @notice Call multiple functions in the current contract and return the data from all of them if they all succeed
    /// @dev The `msg.value` should not be trusted for any method callable from multicall.
    /// @param data The encoded function data for each of the calls to make to this contract
    /// @return results The results from each of the calls passed in via data
    function multicall(bytes[] calldata data) external payable returns (bytes[] memory results);
}

interface INonfungiblePositionManager {
    struct MintParams {
        // CORRECTED: Struct field order now matches the implementation.
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    struct IncreaseLiquidityParams {
        uint256 tokenId;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function PERMIT_TYPEHASH() external view returns (bytes32);
    function WETH9() external view returns (address);
    function approve(address to, uint256 tokenId) external;
    function balanceOf(address owner) external view returns (uint256);
    function baseURI() external pure returns (string memory);
    function burn(uint256 tokenId) external;
    function collect(CollectParams memory params) external returns (uint256 amount0, uint256 amount1);

    // REMOVED: createAndInitializePoolIfNecessary is not part of Kittenswap's position manager.
    // Pool creation is handled within the mint function.

    function decreaseLiquidity(DecreaseLiquidityParams memory params)
        external
        returns (uint256 amount0, uint256 amount1);
    function factory() external view returns (address);
    function getApproved(uint256 tokenId) external view returns (address);
    function increaseLiquidity(IncreaseLiquidityParams memory params)
        external
        returns (uint128 liquidity, uint256 amount0, uint256 amount1);
    function isApprovedForAll(address owner, address operator) external view returns (bool);
    function mint(MintParams memory params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);
    function multicall(bytes[] memory data) external returns (bytes[] memory results);
    function name() external view returns (string memory);
    function ownerOf(uint256 tokenId) external view returns (address);
    function permit(address spender, uint256 tokenId, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            // UPDATED: fee changed to tickSpacing
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        );
    function refundETH() external;
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes memory _data) external;
    function selfPermit(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s) external;
    function selfPermitAllowed(address token, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s) external;
    function selfPermitAllowedIfNecessary(address token, uint256 nonce, uint256 expiry, uint8 v, bytes32 r, bytes32 s)
        external;
    function selfPermitIfNecessary(address token, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function setApprovalForAll(address operator, bool approved) external;
    function supportsInterface(bytes4 interfaceId) external view returns (bool);
    function sweepToken(address token, uint256 amountMinimum, address recipient) external;
    function symbol() external view returns (string memory);
    function tokenByIndex(uint256 index) external view returns (uint256);
    function tokenOfOwnerByIndex(address owner, uint256 index) external view returns (uint256);
    function tokenURI(uint256 tokenId) external view returns (string memory);
    function totalSupply() external view returns (uint256);
    function transferFrom(address from, address to, uint256 tokenId) external;
    function uniswapV3MintCallback(uint256 amount0Owed, uint256 amount1Owed, bytes memory data) external;
    function unwrapWETH9(uint256 amountMinimum, address recipient) external;
}
