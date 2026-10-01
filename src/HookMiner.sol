// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {HookFlags} from "./HookFlags.sol";

/// @title HookMiner
/// @notice Finds a CREATE2 salt that places a hook on an address carrying the required permission bits.
/// @dev Used by the deploy script and the tests. The hook's address is immutable once deployed, so the
/// flags it is mined for must equal what `getHookPermissions()` reports; `HookFlags.matches` checks that.
library HookMiner {
    /// @notice Upper bound on salts tried before giving up.
    uint256 internal constant MAX_LOOP = 400_000;

    error NoSaltFound();

    /// @param deployer The address that will execute CREATE2 (the test contract, or the CREATE2 proxy).
    /// @param flags The permission bits the address must carry.
    /// @param creationCode The hook's creation code with constructor arguments appended.
    /// @return hookAddress The predicted address.
    /// @return salt The salt that produces it.
    function find(address deployer, uint160 flags, bytes memory creationCode)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        return find(deployer, flags, creationCode, 0);
    }

    /// @notice Same as `find`, starting the search at `startSalt` (useful to skip addresses already used).
    function find(address deployer, uint160 flags, bytes memory creationCode, uint256 startSalt)
        internal
        pure
        returns (address hookAddress, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = startSalt; i < startSalt + MAX_LOOP; i++) {
            salt = bytes32(i);
            hookAddress = computeAddress(deployer, salt, initCodeHash);
            if (HookFlags.matches(hookAddress, flags)) return (hookAddress, salt);
        }
        revert NoSaltFound();
    }

    function computeAddress(address deployer, bytes32 salt, bytes32 initCodeHash) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, initCodeHash)))));
    }
}
