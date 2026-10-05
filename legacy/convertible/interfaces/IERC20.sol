// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/**
 * @title IERC20
 * @dev Minimal ERC20 interface for the USDC token.
 */
interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);

    function transfer(address recipient, uint256 amount) external returns (bool);
    function mint(address to, uint256 amount) external;
}
