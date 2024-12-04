// SPDX-License-Identifier: MIT
pragma solidity ^0.8.25;

import {IVault} from "@symbiotic/interfaces/vault/IVault.sol";
import {IBaseDelegator} from "@symbiotic/interfaces/delegator/IBaseDelegator.sol";
import {IRegistry} from "@symbiotic/interfaces/common/IRegistry.sol";
import {IEntity} from "@symbiotic/interfaces/common/IEntity.sol";
import {IVetoSlasher} from "@symbiotic/interfaces/slasher/IVetoSlasher.sol";
import {Subnetwork} from "@symbiotic/contracts/libraries/Subnetwork.sol";
import {ISlasher} from "@symbiotic/interfaces/slasher/ISlasher.sol";
import {IOperatorSpecificDelegator} from "@symbiotic/interfaces/delegator/IOperatorSpecificDelegator.sol";

import {Time} from "@openzeppelin/contracts/utils/types/Time.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {EnumerableMap} from "@openzeppelin/contracts/utils/structs/EnumerableMap.sol";

import {BaseManager} from "./BaseManager.sol";
import {PauseableEnumerableSet} from "../libraries/PauseableEnumerableSet.sol";

/**
 * @title VaultManager
 * @notice Abstract contract for managing vaults and their relationships with operators and subnetworks
 * @dev Extends BaseManager and provides functionality for registering, pausing, and managing vaults
 */
abstract contract VaultManager is BaseManager {
    using EnumerableMap for EnumerableMap.AddressToUintMap;
    using EnumerableMap for EnumerableMap.AddressToAddressMap;
    using PauseableEnumerableSet for PauseableEnumerableSet.AddressSet;
    using PauseableEnumerableSet for PauseableEnumerableSet.Uint160Set;
    using Subnetwork for address;

    error NotVault();
    error NotOperatorVault();
    error VaultNotInitialized();
    error VaultAlreadyRegistered();
    error VaultEpochTooShort();
    error InactiveVaultSlash();
    error UnknownSlasherType();
    error NonVetoSlasher();
    error NoSlasher();
    error TooOldTimestampSlash();
    error NotOperatorSpecificVault();

    /// @custom:storage-location erc7201:symbiotic.storage.VaultManager
    struct VaultManagerStorage {
        PauseableEnumerableSet.Uint160Set _subnetworks;
        PauseableEnumerableSet.AddressSet _sharedVaults;
        mapping(address => PauseableEnumerableSet.AddressSet) _operatorVaults;
        EnumerableMap.AddressToAddressMap _vaultOperator;
    }

    // keccak256(abi.encode(uint256(keccak256("symbiotic.storage.VaultManager")) - 1)) & ~bytes32(uint256(0xff))
    bytes32 private constant VaultManagerStorageLocation =
        0x485f0695561726d087d0cb5cf546efed37ef61dfced21455f1ba7eb5e5b3db00;

    function _getVaultManagerStorage() private pure returns (VaultManagerStorage storage $) {
        assembly {
            $.slot := VaultManagerStorageLocation
        }
    }

    uint64 internal constant OPERATOR_SPECIFIC_DELEGATOR_TYPE = 2;

    /**
     * @dev Struct containing information about a slash response
     * @param vault The address of the vault being slashed
     * @param slasherType The type identifier of the slasher
     * @param subnetwork The subnetwork identifier where the slash occurred
     * @param response For instant slashing: the slashed amount, for veto slashing: the slash index
     */
    struct SlashResponse {
        address vault;
        uint64 slasherType;
        bytes32 subnetwork;
        uint256 response;
    }

    /**
     * @notice Gets the total number of registered subnetworks
     * @return uint256 The count of registered subnetworks
     */
    function subnetworksLength() public view returns (uint256) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._subnetworks.length();
    }

    /**
     * @notice Gets the subnetwork information at a specific index
     * @param pos The index position to query
     * @return uint160 The subnetwork address
     * @return uint48 The time when the subnetwork was enabled
     * @return uint48 The time when the subnetwork was disabled
     */
    function subnetworkWithTimesAt(
        uint256 pos
    ) public view returns (uint160, uint48, uint48) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._subnetworks.at(pos);
    }

    /**
     * @notice Gets all currently active subnetworks
     * @return uint160[] Array of active subnetwork addresses
     */
    function activeSubnetworks() public view returns (uint160[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._subnetworks.getActive(getCaptureTimestamp());
    }

    /**
     * @notice Gets all subnetworks that were active at a specific timestamp
     * @param timestamp The timestamp to check
     * @return uint160[] Array of subnetwork addresses that were active at the timestamp
     */
    function activeSubnetworksAt(
        uint48 timestamp
    ) public view returns (uint160[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._subnetworks.getActive(timestamp);
    }

    /**
     * @notice Checks if a subnetwork was active at a specific timestamp
     * @param timestamp The timestamp to check
     * @param subnetwork The subnetwork identifier
     * @return bool True if the subnetwork was active at the timestamp
     */
    function subnetworkWasActiveAt(uint48 timestamp, uint96 subnetwork) public view returns (bool) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._subnetworks.wasActiveAt(timestamp, uint160(subnetwork));
    }

    /**
     * @notice Gets the total number of shared vaults
     * @return uint256 The count of shared vaults
     */
    function sharedVaultsLength() public view returns (uint256) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.length();
    }

    /**
     * @notice Gets the vault information at a specific index
     * @param pos The index position to query
     * @return address The vault address
     * @return uint48 The time when the vault was enabled
     * @return uint48 The time when the vault was disabled
     */
    function sharedVaultWithTimesAt(
        uint256 pos
    ) public view returns (address, uint48, uint48) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.at(pos);
    }

    /**
     * @notice Gets all currently active shared vaults
     * @return address[] Array of active shared vault addresses
     */
    function activeSharedVaults() public view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.getActive(getCaptureTimestamp());
    }

    /**
     * @notice Gets all shared vaults that were active at a specific timestamp
     * @param timestamp The timestamp to check
     * @return address[] Array of shared vault addresses that were active at the timestamp
     */
    function activeSharedVaultsAt(uint48 timestamp) public view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.getActive(timestamp);
    }

    /**
     * @notice Gets the number of vaults associated with an operator
     * @param operator The operator address to query
     * @return uint256 The count of vaults for the operator
     */
    function operatorVaultsLength(
        address operator
    ) public view returns (uint256) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].length();
    }

    /**
     * @notice Gets the vault information at a specific index for an operator
     * @param operator The operator address
     * @param pos The index position to query
     * @return address The vault address
     * @return uint48 The time when the vault was enabled
     * @return uint48 The time when the vault was disabled
     */
    function operatorVaultWithTimesAt(address operator, uint256 pos) public view returns (address, uint48, uint48) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].at(pos);
    }

    /**
     * @notice Gets all currently active vaults for a specific operator
     * @param operator The operator address
     * @return address[] Array of active vault addresses
     */
    function activeOperatorVaults(
        address operator
    ) public view returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].getActive(getCaptureTimestamp());
    }

    /**
     * @notice Gets all currently active vaults across all operators
     * @return address[] Array of all active vault addresses
     */
    function activeVaults() public view virtual returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        uint48 timestamp = getCaptureTimestamp();
        return activeVaultsAt(timestamp);
    }

    /**
     * @notice Gets all vaults that were active at a specific timestamp
     * @param timestamp The timestamp to check
     * @return address[] Array of vault addresses that were active at the timestamp
     */
    function activeVaultsAt(
        uint48 timestamp
    ) public view virtual returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        address[] memory activeSharedVaults_ = $._sharedVaults.getActive(timestamp);
        uint256 len = activeSharedVaults_.length;
        uint256 operatorVaultsLen = $._vaultOperator.length();
        address[] memory vaults = new address[](len + operatorVaultsLen);

        for (uint256 i; i < len; ++i) {
            vaults[i] = activeSharedVaults_[i];
        }

        for (uint256 i; i < operatorVaultsLen; ++i) {
            (address vault, address operator) = $._vaultOperator.at(i);
            if ($._operatorVaults[operator].wasActiveAt(timestamp, vault)) {
                vaults[len++] = vault;
            }
        }

        assembly {
            mstore(vaults, len)
        }

        return vaults;
    }

    /**
     * @notice Gets all currently active vaults for a specific operator
     * @param operator The operator address
     * @return address[] Array of active vault addresses for the operator
     */
    function activeVaults(
        address operator
    ) public view virtual returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        uint48 timestamp = getCaptureTimestamp();
        return activeVaultsAt(timestamp, operator);
    }

    /**
     * @notice Gets all vaults that were active for an operator at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @return address[] Array of vault addresses that were active at the timestamp
     */
    function activeVaultsAt(uint48 timestamp, address operator) public view virtual returns (address[] memory) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        address[] memory activeSharedVaults_ = $._sharedVaults.getActive(timestamp);
        address[] memory activeOperatorVaults_ = $._operatorVaults[operator].getActive(timestamp);

        uint256 activeSharedVaultsLen = activeSharedVaults_.length;
        uint256 activeOperatorVaultsLen = activeOperatorVaults_.length;
        address[] memory vaults = new address[](activeSharedVaultsLen + activeOperatorVaultsLen);
        for (uint256 i; i < activeSharedVaultsLen; ++i) {
            vaults[i] = activeSharedVaults_[i];
        }
        for (uint256 i; i < activeOperatorVaultsLen; ++i) {
            vaults[activeSharedVaultsLen + i] = activeOperatorVaults_[i];
        }

        return vaults;
    }

    /**
     * @notice Checks if a vault was active at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @param vault The vault address
     * @return bool True if the vault was active at the timestamp
     */
    function vaultWasActiveAt(uint48 timestamp, address operator, address vault) public view returns (bool) {
        return sharedVaultWasActiveAt(timestamp, vault) || operatorVaultWasActiveAt(timestamp, operator, vault);
    }

    /**
     * @notice Checks if a shared vault was active at a specific timestamp
     * @param timestamp The timestamp to check
     * @param vault The vault address
     * @return bool True if the shared vault was active at the timestamp
     */
    function sharedVaultWasActiveAt(uint48 timestamp, address vault) public view returns (bool) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._sharedVaults.wasActiveAt(timestamp, vault);
    }

    /**
     * @notice Checks if an operator vault was active at a specific timestamp
     * @param timestamp The timestamp to check
     * @param operator The operator address
     * @param vault The vault address
     * @return bool True if the operator vault was active at the timestamp
     */
    function operatorVaultWasActiveAt(uint48 timestamp, address operator, address vault) public view returns (bool) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        return $._operatorVaults[operator].wasActiveAt(timestamp, vault);
    }

    /**
     * @notice Gets the stake amount for an operator in a vault and subnetwork at a specific timestamp
     * @param operator The operator address
     * @param vault The vault address
     * @param subnetwork The subnetwork identifier
     * @param timestamp The timestamp to check
     * @return uint256 The stake amount at the timestamp
     */
    function getOperatorStakeAt(
        address operator,
        address vault,
        uint96 subnetwork,
        uint48 timestamp
    ) private view returns (uint256) {
        bytes32 subnetworkId = NETWORK().subnetwork(subnetwork);
        return IBaseDelegator(IVault(vault).delegator()).stakeAt(subnetworkId, operator, timestamp, "");
    }

    /**
     * @notice Gets the power amount for an operator in a vault and subnetwork
     * @param operator The operator address
     * @param vault The vault address
     * @param subnetwork The subnetwork identifier
     * @return uint256 The power amount
     */
    function getOperatorPower(address operator, address vault, uint96 subnetwork) public view returns (uint256) {
        return getOperatorPowerAt(operator, vault, subnetwork, getCaptureTimestamp());
    }

    /**
     * @notice Gets the power amount for an operator in a vault and subnetwork at a specific timestamp
     * @param operator The operator address
     * @param vault The vault address
     * @param subnetwork The subnetwork identifier
     * @param timestamp The timestamp to check
     * @return uint256 The power amount at the timestamp
     */
    function getOperatorPowerAt(
        address operator,
        address vault,
        uint96 subnetwork,
        uint48 timestamp
    ) public view returns (uint256) {
        uint256 stake = getOperatorStakeAt(operator, vault, subnetwork, timestamp);
        return stakeToPower(vault, stake);
    }

    /**
     * @notice Gets the total power amount for an operator across all vaults and subnetworks
     * @param operator The operator address
     * @return power The total power amount
     */
    function getOperatorPower(
        address operator
    ) public view virtual returns (uint256 power) {
        return getOperatorPowerAt(operator, getCaptureTimestamp());
    }

    /**
     * @notice Gets the total power amount for an operator across all vaults and subnetworks at a specific timestamp
     * @param operator The operator address
     * @param timestamp The timestamp to check
     * @return power The total power amount at the timestamp
     */
    function getOperatorPowerAt(address operator, uint48 timestamp) public view virtual returns (uint256 power) {
        address[] memory vaults = activeVaultsAt(timestamp, operator);
        uint160[] memory subnetworks = activeSubnetworksAt(timestamp);

        for (uint256 i; i < vaults.length; ++i) {
            address vault = vaults[i];
            for (uint256 j; j < subnetworks.length; ++j) {
                power += getOperatorPowerAt(operator, vault, uint96(subnetworks[j]), timestamp);
            }
        }

        return power;
    }

    /**
     * @notice Calculates the total power for a list of operators
     * @param operators Array of operator addresses
     * @return power The total power amount
     */
    function _totalPower(
        address[] memory operators
    ) internal view returns (uint256 power) {
        for (uint256 i; i < operators.length; ++i) {
            power += getOperatorPower(operators[i]);
        }

        return power;
    }

    /**
     * @notice Registers a new subnetwork
     * @param subnetwork The subnetwork identifier to register
     */
    function _registerSubnetwork(
        uint96 subnetwork
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._subnetworks.register(Time.timestamp(), uint160(subnetwork));
    }

    /**
     * @notice Pauses a subnetwork
     * @param subnetwork The subnetwork identifier to pause
     */
    function _pauseSubnetwork(
        uint96 subnetwork
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._subnetworks.pause(Time.timestamp(), uint160(subnetwork));
    }

    /**
     * @notice Unpauses a subnetwork
     * @param subnetwork The subnetwork identifier to unpause
     */
    function _unpauseSubnetwork(
        uint96 subnetwork
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._subnetworks.unpause(Time.timestamp(), SLASHING_WINDOW(), uint160(subnetwork));
    }

    /**
     * @notice Unregisters a subnetwork
     * @param subnetwork The subnetwork identifier to unregister
     */
    function _unregisterSubnetwork(
        uint96 subnetwork
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._subnetworks.unregister(Time.timestamp(), SLASHING_WINDOW(), uint160(subnetwork));
    }

    /**
     * @notice Registers a new shared vault
     * @param vault The vault address to register
     */
    function _registerSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        _validateVault(vault);
        $._sharedVaults.register(Time.timestamp(), vault);
    }

    /**
     * @notice Registers a new operator vault
     * @param operator The operator address
     * @param vault The vault address to register
     */
    function _registerOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        _validateVault(vault);
        _validateOperatorVault(operator, vault);

        $._operatorVaults[operator].register(Time.timestamp(), vault);
        $._vaultOperator.set(vault, operator);
    }

    /**
     * @notice Pauses a shared vault
     * @param vault The vault address to pause
     */
    function _pauseSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._sharedVaults.pause(Time.timestamp(), vault);
    }

    /**
     * @notice Unpauses a shared vault
     * @param vault The vault address to unpause
     */
    function _unpauseSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._sharedVaults.unpause(Time.timestamp(), SLASHING_WINDOW(), vault);
    }

    /**
     * @notice Pauses an operator vault
     * @param operator The operator address
     * @param vault The vault address to pause
     */
    function _pauseOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._operatorVaults[operator].pause(Time.timestamp(), vault);
    }

    /**
     * @notice Unpauses an operator vault
     * @param operator The operator address
     * @param vault The vault address to unpause
     */
    function _unpauseOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._operatorVaults[operator].unpause(Time.timestamp(), SLASHING_WINDOW(), vault);
    }

    /**
     * @notice Unregisters a shared vault
     * @param vault The vault address to unregister
     */
    function _unregisterSharedVault(
        address vault
    ) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._sharedVaults.unregister(Time.timestamp(), SLASHING_WINDOW(), vault);
    }

    /**
     * @notice Unregisters an operator vault
     * @param operator The operator address
     * @param vault The vault address to unregister
     */
    function _unregisterOperatorVault(address operator, address vault) internal {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        $._operatorVaults[operator].unregister(Time.timestamp(), SLASHING_WINDOW(), vault);
        $._vaultOperator.remove(vault);
    }

    /**
     * @notice Slashes a vault based on provided conditions
     * @param timestamp The timestamp when the slash occurs
     * @param vault The vault address
     * @param subnetwork The subnetwork identifier
     * @param operator The operator to slash
     * @param amount The amount to slash
     * @param hints Additional data for the slasher
     * @return resp A struct containing information about the slash response
     */
    function _slashVault(
        uint48 timestamp,
        address vault,
        bytes32 subnetwork,
        address operator,
        uint256 amount,
        bytes memory hints
    ) internal returns (SlashResponse memory resp) {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        if (!($._sharedVaults.contains(vault) || $._operatorVaults[operator].contains(vault))) {
            revert NotOperatorVault();
        }

        if (!vaultWasActiveAt(timestamp, operator, vault)) {
            revert InactiveVaultSlash();
        }

        if (timestamp + SLASHING_WINDOW() < Time.timestamp()) {
            revert TooOldTimestampSlash();
        }

        address slasher = IVault(vault).slasher();
        if (slasher == address(0)) {
            revert NoSlasher();
        }

        uint64 slasherType = IEntity(slasher).TYPE();
        resp.vault = vault;
        resp.slasherType = slasherType;
        resp.subnetwork = subnetwork;
        if (slasherType == INSTANT_SLASHER_TYPE) {
            resp.response = ISlasher(slasher).slash(subnetwork, operator, amount, timestamp, hints);
        } else if (slasherType == VETO_SLASHER_TYPE) {
            resp.response = IVetoSlasher(slasher).requestSlash(subnetwork, operator, amount, timestamp, hints);
        } else {
            revert UnknownSlasherType();
        }
    }

    /**
     * @notice Executes a veto-based slash for a vault
     * @param vault The vault address
     * @param slashIndex The index of the slash to execute
     * @param hints Additional data for the veto slasher
     * @return slashedAmount The amount that was slashed
     */
    function _executeSlash(
        address vault,
        uint256 slashIndex,
        bytes calldata hints
    ) internal returns (uint256 slashedAmount) {
        address slasher = IVault(vault).slasher();
        uint64 slasherType = IEntity(slasher).TYPE();
        if (slasherType != VETO_SLASHER_TYPE) {
            revert NonVetoSlasher();
        }

        return IVetoSlasher(slasher).executeSlash(slashIndex, hints);
    }

    /**
     * @notice Validates if a vault is properly initialized and registered
     * @param vault The vault address to validate
     */
    function _validateVault(
        address vault
    ) private view {
        VaultManagerStorage storage $ = _getVaultManagerStorage();
        if (!IRegistry(VAULT_REGISTRY()).isEntity(vault)) {
            revert NotVault();
        }

        if (!IVault(vault).isInitialized()) {
            revert VaultNotInitialized();
        }

        if ($._vaultOperator.contains(vault) || $._sharedVaults.contains(vault)) {
            revert VaultAlreadyRegistered();
        }

        uint48 vaultEpoch = IVault(vault).epochDuration();

        address slasher = IVault(vault).slasher();
        if (slasher != address(0) && IEntity(slasher).TYPE() == VETO_SLASHER_TYPE) {
            vaultEpoch -= IVetoSlasher(slasher).vetoDuration();
        }

        if (vaultEpoch < SLASHING_WINDOW()) {
            revert VaultEpochTooShort();
        }
    }

    function _validateOperatorVault(address operator, address vault) internal view {
        address delegator = IVault(vault).delegator();
        if (
            IEntity(delegator).TYPE() != OPERATOR_SPECIFIC_DELEGATOR_TYPE
                || IOperatorSpecificDelegator(delegator).operator() != operator
        ) {
            revert NotOperatorSpecificVault();
        }
    }
}
