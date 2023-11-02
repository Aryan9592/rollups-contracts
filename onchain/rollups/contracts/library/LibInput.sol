// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {CanonicalMachine} from "../common/CanonicalMachine.sol";

/// @title Input Library
library LibInput {
    using CanonicalMachine for CanonicalMachine.Log2Size;

    /// @notice Raised when input is larger than the machine limit.
    error InputSizeExceedsLimit();

    /// @notice Encode an EVM input
    /// @param sender `msg.sender`
    /// @param blockNumber `block.number`
    /// @param blockTimestamp `block.timestamp`
    /// @param index The index of the input in the input box
    /// @param payload The input payload
    /// @return The encoded EVM input
    function encodeEvmInput(
        address sender,
        uint256 blockNumber,
        uint256 blockTimestamp,
        uint256 index,
        bytes calldata payload
    ) internal pure returns (bytes memory) {
        return
            abi.encodeWithSignature(
                "EvmInput(address,uint256,uint256,uint256,bytes)",
                sender,
                blockNumber,
                blockTimestamp,
                index,
                payload
            );
    }

    /// @notice Summarize input data in a single hash.
    /// @param sender `msg.sender`
    /// @param blockNumber `block.number`
    /// @param blockTimestamp `block.timestamp`
    /// @param index The index of the input in the input box
    /// @param payload The input payload
    /// @return The EVM input hash
    function computeEvmInputHash(
        address sender,
        uint256 blockNumber,
        uint256 blockTimestamp,
        uint256 index,
        bytes calldata payload
    ) internal pure returns (bytes32) {
        bytes memory input = encodeEvmInput(
            sender,
            blockNumber,
            blockTimestamp,
            index,
            payload
        );

        if (input.length > CanonicalMachine.INPUT_MAX_SIZE) {
            revert InputSizeExceedsLimit();
        }

        return keccak256(input);
    }
}
