// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Bytes32AddressLib} from "solmate/utils/Bytes32AddressLib.sol";

/// @title CREATE2Helper
/// @notice Helper library for generating CREATE2 salts and predicting deployment addresses
/// @dev Allows finding salts that result in addresses with specific relationships to target addresses
library CREATE2Helper {
    using Bytes32AddressLib for bytes32;

    /// @notice Finds a salt that will result in a contract address with desired relationship to target
    /// @param deployer Address of the contract performing the CREATE2 deployment
    /// @param constructorArgs Encoded constructor arguments
    /// @param creationCode Contract creation code
    /// @param targetAddress Address to compare resulting address against
    /// @param greaterThan If true, finds address > target, if false finds address < target
    /// @return salt The generated salt
    /// @return predictedAddress The address where contract will be deployed
    function generateSalt(
        address deployer,
        bytes memory constructorArgs,
        bytes memory creationCode,
        address targetAddress,
        bool greaterThan
    ) public view returns (bytes32 salt, address predictedAddress) {
        for (uint256 i;; i++) {
            salt = bytes32(i);
            predictedAddress = predictAddress(deployer, salt, constructorArgs, creationCode);
            if (greaterThan ? predictedAddress > targetAddress : predictedAddress < targetAddress) {
                if (predictedAddress.code.length == 0) break;
            }
        }
    }

    /// @notice Predicts the address where a contract will be deployed using CREATE2
    /// @param deployer Address of the contract performing the CREATE2 deployment
    /// @param salt Salt to be used in CREATE2
    /// @param constructorArgs Encoded constructor arguments
    /// @param creationCode Contract creation code
    /// @return result The predicted deployment address
    function predictAddress(address deployer, bytes32 salt, bytes memory constructorArgs, bytes memory creationCode)
        public
        pure
        returns (address result)
    {
        bytes32 deploymentHash = keccak256(bytes.concat(creationCode, constructorArgs));
        result = keccak256(abi.encodePacked(bytes1(0xFF), deployer, salt, deploymentHash)).fromLast20Bytes();
    }
}
