// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {IInputBox} from "./IInputBox.sol";
import {LibInput} from "../library/LibInput.sol";

/// @title Input Box
///
/// @notice Trustless and permissionless contract that receives arbitrary
/// data from anyone and adds a compound hash to an append-only list
/// (called "input box"). Each DApp has its own input box.
///
/// The input hash is composed by the input payload, the block number and timestamp,
/// the address of the input sender, and the index of the input.
///
/// Data availability is guaranteed by the emission of `InputAdded` events
/// on every successful call to `addInput`. This ensures that inputs can be
/// retrieved by anyone at any time, without having to rely on centralized data
/// providers.
///
/// From the perspective of this contract, inputs are encoding-agnostic byte
/// arrays. It is up to the DApp to interpret, validate and act upon inputs.
contract InputBox is IInputBox {
    /// @notice Mapping from DApp address to list of input hashes.
    /// @dev See the `getNumberOfInputs`, `getInputHash` and `addInput` functions.
    mapping(address => bytes32[]) internal inputBoxes;

    function addInput(
        address _dapp,
        bytes calldata _payload
    ) external override returns (bytes32) {
        bytes32[] storage inputBox = inputBoxes[_dapp];
        uint256 index = inputBox.length;

        bytes32 inputHash = LibInput.computeEvmInputHash(
            msg.sender,
            block.number,
            block.timestamp,
            index,
            _payload
        );

        // add input to the input box
        inputBox.push(inputHash);

        // block.number and timestamp can be retrieved by the event metadata itself
        emit InputAdded(_dapp, index, msg.sender, _payload);

        return inputHash;
    }

    function getNumberOfInputs(
        address _dapp
    ) external view override returns (uint256) {
        return inputBoxes[_dapp].length;
    }

    function getInputHash(
        address _dapp,
        uint256 _index
    ) external view override returns (bytes32) {
        return inputBoxes[_dapp][_index];
    }
}
