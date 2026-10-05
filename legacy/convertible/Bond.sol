// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";

import {TickMath} from "./lib/external/TickMath.sol";
import {BondPricerLib} from "./lib/BondPricerLib.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {IUniswapV3Pool} from "./interfaces/IUniswap.sol";
import {IBondFactory} from "./interfaces/IBondFactory.sol";

/// @title Bond
/// @notice A bond contract that allows users to mint bonds with USDC and redeem them for either USDC or asset tokens
/// @dev Uses Uniswap V3 TWAP for price oracle at expiry. Requires pool with ASSET as token0 and USDC as token1
contract Bond is ERC20, Owned {
    // ----------------
    // Bond parameters
    // ----------------
    address private constant USDC = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    uint32 public constant TWAP_INTERVAL = 1800; // 30 minutes

    uint256 public maxUsdc; // Maximum USDC deposit for this bond
    uint256 public issuanceEnd; // Timestamp upto which minting can happen
    uint256 public bondExpiry; // Timestamp after which redemption can happen
    uint256 public usdcDeposited; // Track total USDC deposited
    uint160 public sqrtStrikePriceX96; // Strike price for the underlying asset
    uint160 public sqrtExpiryPriceX96; // Price of the underlying asset/USDC at expiry
    address public bondFactory; // Address of the bond factory
    address public assetUSDCPool; // Address of the pool (Asset/USDC)

    // ----------------
    // Events
    // ----------------
    event MintBonds(address indexed user, uint256 amountUsdc, uint256 bondsMinted, uint256 strikePrice);

    event RedeemBonds(address indexed user, uint256 amountBonds, uint256 amountInAsset);
    event FinalizeBondPrice(uint256 sqrtExpiryPriceX96);

    /// @notice Creates a new bond contract
    /// @param _name Name of the bond token
    /// @param _symbol Symbol of the bond token
    /// @param _decimals Decimal places for the bond token
    /// @param _maxUsdc Maximum amount of USDC that can be deposited
    /// @param _issuanceEnd Timestamp when bond issuance ends
    /// @param _bondExpiry Timestamp when bond expires
    /// @param _sqrtStrikePriceX96 Strike price in sqrt price X96 format
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _maxUsdc,
        uint256 _issuanceEnd,
        uint256 _bondExpiry,
        uint160 _sqrtStrikePriceX96,
        address _owner
    ) ERC20(_name, _symbol, _decimals) Owned(_owner) {
        maxUsdc = _maxUsdc;
        issuanceEnd = _issuanceEnd;
        bondExpiry = _bondExpiry;
        sqrtStrikePriceX96 = _sqrtStrikePriceX96;
        bondFactory = msg.sender;
    }

    // ----------------
    // Bond logic
    // ----------------

    /// @notice Allows users to mint bond tokens by depositing USDC
    /// @param amountUsdc Amount of USDC to deposit
    function mintBonds(uint256 amountUsdc) external {
        require(amountUsdc > 0, "Bond: amount must be > 0");
        require(block.timestamp < issuanceEnd, "Bond: cannot mint after bond issuanceEnd");
        require(usdcDeposited + amountUsdc <= maxUsdc, "Bond: exceeds max USDC deposit");

        // Transfer USDC from sender to this contract
        IERC20(USDC).transferFrom(msg.sender, address(this), amountUsdc);

        // Mint ABOND tokens to sender, need to adjust for USDC 6 decimals
        _mint(msg.sender, amountUsdc * 10 ** 12);

        usdcDeposited += amountUsdc;
        emit MintBonds(msg.sender, amountUsdc, amountUsdc, sqrtStrikePriceX96);
    }

    /// @notice Redeems bond tokens for USDC or asset tokens based on expiry price
    /// @dev If expiry price <= strike price, redeems for USDC, otherwise for asset tokens
    /// @param amountBonds Amount of bond tokens to redeem
    function redeemBonds(uint256 amountBonds) external {
        require(block.timestamp >= bondExpiry, "Bond: not yet matured");
        require(amountBonds > 0, "Bond: amount must be > 0");

        _finalizeBondPrice();
        _burn(msg.sender, amountBonds);

        uint256 amountInAsset;

        uint256 usdcValue = amountBonds / 10 ** 12;
        if (sqrtExpiryPriceX96 <= sqrtStrikePriceX96) {
            IERC20(USDC).transfer(msg.sender, usdcValue);
        } else {
            amountInAsset = BondPricerLib.getAssetAmountFromBond(usdcValue, sqrtStrikePriceX96);
            IBondFactory(bondFactory).mintOnRedemption(amountInAsset, msg.sender);
        }

        emit RedeemBonds(msg.sender, amountBonds, amountInAsset);
    }

    /// @notice Sets the Asset/USDC Uniswap V3 pool for price oracle
    /// @dev Pool must have ASSET as token0 and USDC as token1 for correct price calculations
    /// @param _pool Address of the Uniswap V3 pool
    function setPool(address _pool) external onlyOwner {
        assetUSDCPool = _pool;
    }

    /// @dev Finalizes the bond price using TWAP at expiry if not already set
    function _finalizeBondPrice() internal {
        if (sqrtExpiryPriceX96 != 0) return;

        sqrtExpiryPriceX96 = _getSqrtExpiryPriceX96();

        emit FinalizeBondPrice(sqrtExpiryPriceX96);
    }

    /// @dev Gets the TWAP sqrt price for Asset/USDC at expiry using Uniswap V3 oracle
    /// @dev First tries with bond expiry timestamp, falls back to current timestamp if that fails
    /// @return The sqrt price in X96 format
    function _getSqrtExpiryPriceX96() public view returns (uint160) {
        uint32[] memory secondsAgos = new uint32[](2);

        // note: you can use secondsagos as below if you want to be precise
        // secondsAgos[0] = block.timestamp - bondExpiry - TWAP_INTERVAL
        // secondsAgos[1] = block.timestamp - bondExpiry
        secondsAgos[0] = TWAP_INTERVAL;
        secondsAgos[1] = 0;

        // using ticks instead of sqrt (opinionated)
        (int56[] memory tickCumulatives,) = IUniswapV3Pool(assetUSDCPool).observe(secondsAgos);

        int56 tickCumulativesDelta = tickCumulatives[1] - tickCumulatives[0];

        int24 twapAtExpiry = int24(tickCumulativesDelta / int56(uint56(TWAP_INTERVAL)));
        return TickMath.getSqrtRatioAtTick(twapAtExpiry);
    }

    /// @notice Allows owner to rescue any tokens (including USDC)
    /// @param asset Address of the token to rescue
    /// @param amount Amount of the token to rescue
    function rescueAsset(address asset, uint256 amount) external onlyOwner {
        IERC20(asset).transfer(msg.sender, amount);
    }
}
