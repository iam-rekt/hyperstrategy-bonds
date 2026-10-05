// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC20} from "solmate/tokens/ERC20.sol";
import {Owned} from "solmate/auth/Owned.sol";

/// @title MintableERC20
/// @notice ERC20 token that can be minted by an authorized bond factory for bond redemptions
/// @dev Only the bond factory can mint new tokens, initial supply is minted to deployer
contract MintableERC20 is ERC20, Owned {
    address public bondFactory;

    /// @notice Creates a new mintable ERC20 token
    /// @param _name Token name
    /// @param _symbol Token symbol
    /// @param _decimals Token decimal places
    /// @param _supply Initial token supply
    /// @param _bondFactory Address of the authorized bond factory
    /// @param _owner Address of the owner (initial token supply is minted to this address)
    constructor(
        string memory _name,
        string memory _symbol,
        uint8 _decimals,
        uint256 _supply,
        address _bondFactory,
        address _owner
    ) ERC20(_name, _symbol, _decimals) Owned(_owner) {
        bondFactory = _bondFactory;
        _mint(_owner, _supply);
    }

    /// @dev Restricts function access to the bond factory
    modifier onlyBondFactory() {
        require(msg.sender == bondFactory, "Only bond factory can call this function");
        _;
    }

    /// @notice Mints new tokens to a specified address
    /// @dev Can only be called by the authorized bond factory during bond redemption
    /// @param to Address to receive the tokens
    /// @param amount Amount of tokens to mint
    function mint(address to, uint256 amount) external onlyBondFactory {
        _mint(to, amount);
    }

    /// @notice Allows the owner to update the bond factory address
    /// @param newFactory The new bond factory address
    function setBondFactory(address newFactory) external onlyOwner {
        bondFactory = newFactory;
    }
}
