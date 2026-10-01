// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {BuyOnlyVoteHook} from "../src/BuyOnlyVoteHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title Deploy
/// @notice Rehearsal of the launch deployment: the token and the hook, with the hook placed by CREATE2
/// on an address carrying its permission bits. In production the IMD launch factory performs these
/// steps itself; this script reads no keys and holds no secrets.
///
/// Environment read by `run()` (none of it is a secret):
///  - EXPECTED_CHAIN_ID: 0 or unset to accept the connected chain, otherwise it must equal
///    `block.chainid`. Only 31337 (local) and 11155111 (Sepolia) are accepted at all.
///  - POOL_MANAGER: the chain's Uniswap v4 PoolManager. Required on Sepolia. On 31337 it may be left
///    unset, in which case a fresh PoolManager is deployed for the rehearsal.
contract Deploy is Script {
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    /// @notice The deterministic CREATE2 proxy forge routes `new X{salt: s}()` through under broadcast.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;

    /// @notice The permission bits the hook address must carry.
    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;

    struct Config {
        /// Expected chain id, or 0 to accept whatever chain is connected.
        uint256 expectedChainId;
        /// PoolManager to bind the hook to; zero on the local chain means "deploy a fresh one".
        address poolManager;
        /// The address that executes CREATE2 for the hook (the proxy under broadcast, the caller otherwise).
        address create2Deployer;
    }

    error ChainIdMismatch(uint256 expected, uint256 actual);
    error UnsupportedChain(uint256 chainId);
    error PoolManagerRequired();
    error HookAddressMismatch(address expected, address actual);

    function run() external returns (SurfToken token, BuyOnlyVoteHook hook, IPoolManager poolManager) {
        Config memory cfg = Config({
            expectedChainId: vm.envOr("EXPECTED_CHAIN_ID", uint256(0)),
            poolManager: vm.envOr("POOL_MANAGER", address(0)),
            create2Deployer: CREATE2_DEPLOYER
        });
        return deploy(cfg);
    }

    /// @notice Deploys the token and the hook according to `cfg`. Tests call this directly.
    function deploy(Config memory cfg)
        public
        returns (SurfToken token, BuyOnlyVoteHook hook, IPoolManager poolManager)
    {
        if (cfg.expectedChainId != 0 && cfg.expectedChainId != block.chainid) {
            revert ChainIdMismatch(cfg.expectedChainId, block.chainid);
        }
        if (block.chainid != LOCAL_CHAIN_ID && block.chainid != SEPOLIA_CHAIN_ID) {
            revert UnsupportedChain(block.chainid);
        }
        if (cfg.poolManager == address(0) && block.chainid != LOCAL_CHAIN_ID) revert PoolManagerRequired();

        vm.startBroadcast();

        poolManager = cfg.poolManager == address(0)
            ? IPoolManager(address(new PoolManager(address(0))))
            : IPoolManager(cfg.poolManager);

        token = new SurfToken();

        bytes memory creationCode = abi.encodePacked(type(BuyOnlyVoteHook).creationCode, abi.encode(poolManager));
        (address predicted, bytes32 salt) = HookMiner.find(cfg.create2Deployer, HOOK_FLAGS, creationCode);
        hook = new BuyOnlyVoteHook{salt: salt}(poolManager);
        if (address(hook) != predicted) revert HookAddressMismatch(predicted, address(hook));

        vm.stopBroadcast();
    }
}
