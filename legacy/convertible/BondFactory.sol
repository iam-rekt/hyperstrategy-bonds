// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Owned} from "solmate/auth/Owned.sol";

import {IERC20} from "./interfaces/IERC20.sol";
import {Bond} from "./Bond.sol";

/// @title BondFactory
/// @notice Factory contract for creating and managing bond programs
/// @dev Controls bond deployment and asset token minting permissions
contract BondFactory is Owned {
    address public constant USDC = 0xB8CE59FC3717ada4C02eaDF9682A9e934F625ebb;
    mapping(address => bool) public isBond;
    address public assetToken;

    event BondCreated(address indexed bondAddress, string name, string symbol);

    /// @param _owner Address of the contract owner
    constructor(address _owner) Owned(_owner) {}

    /// @notice Creates a new bond program with specified parameters
    /// @param bondName Name of the bond token
    /// @param bondSymbol Symbol of the bond token
    /// @param decimals Decimal places for the bond token
    /// @param sqrtStrikePriceX96 The strike price in sqrt price X96 format for Asset/USDC
    /// @param maxUsdc Maximum amount of USDC that can be deposited
    /// @param issuanceEnd Timestamp when bond issuance ends
    /// @param bondExpiry Timestamp when bond expires and can be redeemed
    /// @return Address of the newly created bond contract
    function createBondProgram(
        string calldata bondName,
        string calldata bondSymbol,
        uint8 decimals,
        uint160 sqrtStrikePriceX96,
        uint256 maxUsdc,
        uint256 issuanceEnd,
        uint256 bondExpiry
    ) external onlyOwner returns (address) {
        Bond bond =
            new Bond(bondName, bondSymbol, decimals, maxUsdc, issuanceEnd, bondExpiry, sqrtStrikePriceX96, owner);

        isBond[address(bond)] = true;
        emit BondCreated(address(bond), bondName, bondSymbol);

        return address(bond);
    }

    /// @notice Sets the asset token address that will be minted on redemption
    /// @param _assetToken Address of the asset token contract
    function setAssetToken(address _assetToken) external onlyOwner {
        require(_assetToken != address(0), "BondFactory: invalid token address");
        require(assetToken == address(0), "BondFactory: asset token already set");
        assetToken = _assetToken;
    }

    /// @notice Mints Asset tokens to a specified address
    /// @dev Can only be called by valid bond contracts
    /// @param amount Amount of tokens to mint
    /// @param to Address to receive the minted tokens
    function mintOnRedemption(uint256 amount, address to) external {
        require(isBond[msg.sender], "BondFactory: not a valid bond");
        IERC20(assetToken).mint(to, amount);
    }
}
