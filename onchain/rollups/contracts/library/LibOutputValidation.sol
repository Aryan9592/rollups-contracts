// (c) Cartesi and individual authors (see AUTHORS)
// SPDX-License-Identifier: Apache-2.0 (see LICENSE)

pragma solidity ^0.8.8;

import {CanonicalMachine} from "../common/CanonicalMachine.sol";
import {MerkleV2} from "@cartesi/util/contracts/MerkleV2.sol";

/// @param inputIndexWithinEpoch Which input, inside the epoch, the output belongs to (G)
/// @param outputIndexWithinInput Index of output emitted by the input (D)
/// @param outputHashesRootHash Merkle root of hashes of outputs emitted by the input (F)
/// @param outputsEpochRootHash Merkle root of all epoch's voucher metadata hashes (I)
/// @param machineStateHash Hash of the machine state claimed this epoch (J)
/// @param outputHashInOutputHashesSiblings Proof that this output metadata is in metadata memory range (E)
/// @param outputHashesInEpochSiblings Proof that this output metadata is in epoch's output memory range (H)
struct OutputValidityProof {
    uint64 inputIndexWithinEpoch;
    uint64 outputIndexWithinInput;
    bytes32 outputHashesRootHash;
    bytes32 outputsEpochRootHash;
    bytes32 machineStateHash;
    bytes32[] outputHashInOutputHashesSiblings;
    bytes32[] outputHashesInEpochSiblings;
}

/// @title Output Validation Library
///
/// @notice The diagram below aims to better illustrate the algorithm
/// behind calculating the epoch hash. Each component in the diagram is
/// labeled, so it can be more easily referenced in this documentation.
/// The diagram is laid out in a top-down fashion, with the epoch hash
/// being the top-most component, but the text will traverse the diagram
/// in a bottom-up fashion.
///
/// The off-chain machine may, while processing an input, generate
/// zero or more outputs. For the scope of this algorithm, let us assume
/// that an output is an arbitrary array of bytes.
///
/// Every output is hashed into a 256-bit word (A), which is then
/// divided into four 64-bit words. From these words, a Merkle tree
/// is constructed from the bottom up (B). The result is a Merkle
/// root hash (C) that fully represents the contents of the output.
///
/// Now, this process is repeated for every output generated by an input.
/// The Merkle root hashes (C) derived from these outputs are then ordered
/// from oldest to newest (D), and used to construct yet another Merkle tree
/// (E). The result is a Merkle root hash (F) that fully represents the
/// contents of every output generated by an input.
///
/// We once again repeat this process, but now for every input accepted in a
/// certain epoch. Then, we organize the Merkle root hashes (F) calculated
/// in the previous step and order them from oldest to newest (G). From these
/// Merkle root hashes (F), we build a final Merkle tree (H). The result is
/// a Merkle root hash (I) that fully represents the contents of every output
/// generated by every input in a certain epoch.
///
/// Finally, this Merkle root hash (I) is combined with the machine state
/// hash (J) to obtain the epoch hash (K).
///
/// ```
///                     ┌──────────────┐
///           ┌─────────┤Epoch Hash (K)├────────┐
///           │         └──────────────┘        │
///           │                                 │
///           │                                 │
///           │                      ┌──────────▼───────────┐
///           │                      │Machine State Hash (J)│
///           │                      └──────────────────────┘
///     ┌─────▼─────┐
///     │Merkle Root│ ───> Epoch's output hashes root hash (I)
///     └───────────┘
///           x
///          xxx         │
///         xxxxx        │
///        xxxxxxx       │
///       xxxxxxxxx      ├──> Epoch's outputs Merkle tree (H)
///      xxxxxxxxxxx     │
///     xxxxxxxxxxxxx    │
///    xxxxxxxxxxxxxxx   │
///   xxxxxxxxxxxxxxxxx
/// ┌────────┬─┬────────┐
/// │   ...  │┼│  ...   │ ───> For each input in the epoch (G)
/// └────────┴┼┴────────┘
///           │
///           │
///     ┌─────▼─────┐
///     │Merkle Root│ ───> Input's output hashes Merkle root hash (F)
///     └───────────┘
///           x
///          xxx         │
///         xxxxx        │
///        xxxxxxx       │
///       xxxxxxxxx      ├──> Input's outputs Merkle tree (E)
///      xxxxxxxxxxx     │
///     xxxxxxxxxxxxx    │
///    xxxxxxxxxxxxxxx   │
///   xxxxxxxxxxxxxxxxx
/// ┌────────┬─┬────────┐
/// │   ...  │┼│  ...   │ ───> For each output from the input (D)
/// └────────┴┼┴────────┘
///           │
///           │
///     ┌─────▼─────┐
///     │Merkle Root│ ───> Output hash Merkle root hash (C)
///     └───────────┘
///           x
///          x x         │
///         x   x        │
///        x     x       │
///       x       x      ├──> Output hash Merkle tree (B)
///      x         x     │
///     x x       x x    │
///    x   x     x   x   │
///   x     x   x     x
/// ┌────┬────┬────┬────┐
/// │    │    │    │    │ ───> Output hash (A)
/// └────┴────┴────┴────┘
/// ```
///
library LibOutputValidation {
    using CanonicalMachine for CanonicalMachine.Log2Size;

    /// @notice Raised when some `OutputValidityProof` variables does not match
    ///         the presented finalized epoch.
    error IncorrectEpochHash();

    /// @notice Raised when `OutputValidityProof` metadata memory range is NOT
    ///         contained in epoch's output memory range.
    error IncorrectOutputsEpochRootHash();

    /// @notice Raised when Merkle root of output hash is NOT contained
    ///         in the output metadata array memory range.
    error IncorrectOutputHashesRootHash();

    /// @notice Raised when epoch input index is NOT compatible with the
    ///         provided input index range.
    error InputIndexOutOfClaimBounds();

    /// @notice Make sure the output proof is valid, otherwise revert.
    /// @param v The output validity proof (D..J)
    /// @param output The output (which, when ABI-encoded and Keccak256-hashed, becomes A,
    ///               and, when Merkelized, generates tree B and root hash C)
    /// @param epochHash The hash of the epoch in which the output was generated (K)
    function validateOutput(
        OutputValidityProof calldata v,
        bytes memory output,
        bytes32 epochHash
    ) internal pure {
        // prove that outputs hash is represented in a finalized epoch
        if (
            keccak256(
                abi.encodePacked(v.outputsEpochRootHash, v.machineStateHash)
            ) != epochHash
        ) {
            revert IncorrectEpochHash();
        }

        // prove that output metadata memory range is contained in epoch's output memory range
        if (
            MerkleV2.getRootAfterReplacementInDrive(
                CanonicalMachine.getIntraMemoryRangePosition(
                    v.inputIndexWithinEpoch,
                    CanonicalMachine.KECCAK_LOG2_SIZE
                ),
                CanonicalMachine.KECCAK_LOG2_SIZE.uint64OfSize(),
                CanonicalMachine.EPOCH_OUTPUT_LOG2_SIZE.uint64OfSize(),
                v.outputHashesRootHash,
                v.outputHashesInEpochSiblings
            ) != v.outputsEpochRootHash
        ) {
            revert IncorrectOutputsEpochRootHash();
        }

        // The hash of the output is converted to bytes (abi.encode) and
        // treated as data. The metadata output memory range stores that data while
        // being indifferent to its contents. To prove that the received
        // output is contained in the metadata output memory range we need to
        // prove that x, where:
        // x = keccak(
        //          keccak(
        //              keccak(hashOfOutput[0:7]),
        //              keccak(hashOfOutput[8:15])
        //          ),
        //          keccak(
        //              keccak(hashOfOutput[16:23]),
        //              keccak(hashOfOutput[24:31])
        //          )
        //     )
        // is contained in it. We can't simply use hashOfOutput because the
        // log2size of the leaf is three (8 bytes) not  five (32 bytes)
        bytes32 merkleRootOfHashOfOutput = MerkleV2.getMerkleRootFromBytes(
            abi.encodePacked(keccak256(abi.encode(output))),
            CanonicalMachine.KECCAK_LOG2_SIZE.uint64OfSize()
        );

        // prove that Merkle root of bytes(hashOfOutput) is contained
        // in the output metadata array memory range
        if (
            MerkleV2.getRootAfterReplacementInDrive(
                CanonicalMachine.getIntraMemoryRangePosition(
                    v.outputIndexWithinInput,
                    CanonicalMachine.KECCAK_LOG2_SIZE
                ),
                CanonicalMachine.KECCAK_LOG2_SIZE.uint64OfSize(),
                CanonicalMachine.OUTPUT_METADATA_LOG2_SIZE.uint64OfSize(),
                merkleRootOfHashOfOutput,
                v.outputHashInOutputHashesSiblings
            ) != v.outputHashesRootHash
        ) {
            revert IncorrectOutputHashesRootHash();
        }
    }

    /// @notice Get the position of a voucher on the bit mask.
    /// @param voucher The index of voucher from those generated by such input
    /// @param input The index of the input in the DApp's input box
    /// @return Position of the voucher on the bit mask
    function getBitMaskPosition(
        uint256 voucher,
        uint256 input
    ) internal pure returns (uint256) {
        // voucher * 2 ** 128 + input
        // this shouldn't overflow because it is impossible to have > 2**128 vouchers
        // and because we are assuming there will be < 2 ** 128 inputs on the input box
        return (((voucher << 128) | input));
    }

    /// @notice Validate input index range and get the input index.
    /// @param v The output validity proof
    /// @param firstInputIndex The index of the first input of the epoch in the input box
    /// @param lastInputIndex The index of the last input of the epoch in the input box
    /// @return The index of the input in the DApp's input box
    /// @dev Reverts if epoch input index is not compatible with the provided input index range.
    function validateInputIndexRange(
        OutputValidityProof calldata v,
        uint256 firstInputIndex,
        uint256 lastInputIndex
    ) internal pure returns (uint256) {
        uint256 inputIndex = firstInputIndex + v.inputIndexWithinEpoch;

        if (inputIndex > lastInputIndex) {
            revert InputIndexOutOfClaimBounds();
        }

        return inputIndex;
    }
}
