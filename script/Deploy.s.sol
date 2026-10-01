// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {BuyOnlyVoteHook} from "../src/BuyOnlyVoteHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {HookMiner} from "../src/HookMiner.sol";

/// @title Deploy
/// @notice Rehearsal of the launch deployment: the token, the hook placed by CREATE2 on an address
/// carrying its permission bits, and the ETH/SURF pool initialized through the hook, all in one
/// broadcast. Initializing here, rather than leaving it to a later operator transaction, closes the
/// gap in which anyone could bind the freshly deployed hook to a stray pool (the hook binds to the
/// first pool initialized through it). In production the IMD launch factory performs these steps
/// itself in a single transaction; this script reads no keys and holds no secrets.
///
/// Environment read by `run()` (none of it is a secret):
///  - EXPECTED_CHAIN_ID: 0 or unset to accept the connected chain, otherwise it must equal
///    `block.chainid`. Only 31337 (local) and 11155111 (Sepolia) are accepted at all.
///  - POOL_MANAGER: the chain's Uniswap v4 PoolManager. Required on Sepolia. On 31337 it may be left
///    unset, in which case a fresh PoolManager is deployed for the rehearsal.
///  - SQRT_PRICE_X96: initial pool price; defaults to 2^96 (1 SURF per ETH).
///  - TICK_SPACING: pool tick spacing; defaults to 60.
///  - SALT_START: first CREATE2 salt to try; defaults to 0. Bump it if the predicted hook address
///    already has code (someone deployed the same creation code through the public proxy first).
contract Deploy is Script {
    uint256 public constant LOCAL_CHAIN_ID = 31337;
    uint256 public constant SEPOLIA_CHAIN_ID = 11155111;
    /// @notice The deterministic CREATE2 proxy forge routes `new X{salt: s}()` through under broadcast.
    address public constant CREATE2_DEPLOYER = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    /// @notice Default initial price: sqrt(1) * 2^96, one SURF per ETH.
    uint160 public constant DEFAULT_SQRT_PRICE_X96 = 79228162514264337593543950336;
    /// @notice Default tick spacing.
    int24 public constant DEFAULT_TICK_SPACING = 60;
    /// @notice The pool's LP fee. The hook refuses any other value: the brief says "no fees".
    uint24 public constant POOL_FEE = 0;

    /// @notice The permission bits the hook address must carry.
    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_ADD_LIQUIDITY
        | HookFlags.AFTER_REMOVE_LIQUIDITY | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP;

    struct Config {
        /// Expected chain id, or 0 to accept whatever chain is connected.
        uint256 expectedChainId;
        /// PoolManager to bind the hook to; zero on the local chain means "deploy a fresh one".
        address poolManager;
        /// The address that executes CREATE2 for the hook (the proxy under broadcast, the caller otherwise).
        address create2Deployer;
        /// Initial sqrt price of the pool (Q64.96).
        uint160 sqrtPriceX96;
        /// Tick spacing of the pool.
        int24 tickSpacing;
        /// First CREATE2 salt to try when mining the hook address.
        uint256 saltStart;
    }

    error ChainIdMismatch(uint256 expected, uint256 actual);
    error UnsupportedChain(uint256 chainId);
    error PoolManagerRequired();
    error HookAddressMismatch(address expected, address actual);
    error HookAddressTaken(address predicted);

    function run() external returns (SurfToken token, BuyOnlyVoteHook hook, IPoolManager poolManager) {
        Config memory cfg = Config({
            expectedChainId: vm.envOr("EXPECTED_CHAIN_ID", uint256(0)),
            poolManager: vm.envOr("POOL_MANAGER", address(0)),
            create2Deployer: CREATE2_DEPLOYER,
            sqrtPriceX96: uint160(vm.envOr("SQRT_PRICE_X96", uint256(DEFAULT_SQRT_PRICE_X96))),
            tickSpacing: int24(vm.envOr("TICK_SPACING", int256(DEFAULT_TICK_SPACING))),
            saltStart: vm.envOr("SALT_START", uint256(0))
        });
        return deploy(cfg);
    }

    /// @notice The pool key the launch pool uses for a given token and hook.
    function poolKey(SurfToken token, BuyOnlyVoteHook hook, int24 tickSpacing) public pure returns (PoolKey memory) {
        return PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(token)),
            fee: POOL_FEE,
            tickSpacing: tickSpacing,
            hooks: IHooks(address(hook))
        });
    }

    /// @notice Deploys the token and the hook and initializes the pool according to `cfg`. Tests call
    /// this directly.
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
        (address predicted, bytes32 salt) = HookMiner.find(cfg.create2Deployer, HOOK_FLAGS, creationCode, cfg.saltStart);
        if (predicted.code.length != 0) revert HookAddressTaken(predicted);
        hook = new BuyOnlyVoteHook{salt: salt}(poolManager);
        if (address(hook) != predicted) revert HookAddressMismatch(predicted, address(hook));

        // Bind the hook to its pool in the same broadcast, so no stray pool can claim it first.
        poolManager.initialize(poolKey(token, hook, cfg.tickSpacing), cfg.sqrtPriceX96);

        vm.stopBroadcast();
    }
}
