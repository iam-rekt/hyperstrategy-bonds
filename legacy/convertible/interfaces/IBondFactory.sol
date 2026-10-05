// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

interface IBondFactory {
    function mintOnRedemption(uint256 amount, address to) external;
}
