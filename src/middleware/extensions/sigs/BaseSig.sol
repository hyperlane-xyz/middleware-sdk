// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

abstract contract BaseSig {
    /**
     * @notice Verifies that a signature was created by the owner of a key
     * @param operator The address of the operator that owns the key
     * @param key_ The public key to verify against
     * @param signature The signature to verify
     * @return True if the signature was created by the key owner, false otherwise
     */
    function _verifyKeySignature(
        address operator,
        bytes memory key_,
        bytes memory signature
    ) internal view virtual returns (bool);
}