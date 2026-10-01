// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {CustomRevert} from "v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {BuyOnlyVoteHook} from "../src/BuyOnlyVoteHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract DeployTest is Test {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    Deploy script;
    address c2;
    uint160 sqrtPrice;
    int24 spacing;

    function setUp() public {
        vm.warp(1_700_000_000);
        script = new Deploy();
        c2 = script.CREATE2_DEPLOYER();
        sqrtPrice = script.DEFAULT_SQRT_PRICE_X96();
        spacing = script.DEFAULT_TICK_SPACING();
    }

    function config(uint256 chainId, address pm, uint256 saltStart) internal view returns (Deploy.Config memory) {
        return Deploy.Config({
            expectedChainId: chainId,
            poolManager: pm,
            create2Deployer: c2,
            sqrtPriceX96: sqrtPrice,
            tickSpacing: spacing,
            saltStart: saltStart
        });
    }

    function test_deployLocallyWithAFreshPoolManagerAndInitializeThePool() public {
        (SurfToken token, BuyOnlyVoteHook hook, IPoolManager pm) = script.deploy(config(31337, address(0), 0));
        assertTrue(address(pm).code.length > 0);
        assertEq(address(hook.poolManager()), address(pm));
        assertEq(HookFlags.flagsOf(address(hook)), script.HOOK_FLAGS());
        assertEq(token.totalSupply(), 10 ** 27);

        // The pool is bound in the same run as the deployment.
        PoolKey memory key = script.poolKey(token, hook, spacing);
        assertEq(key.fee, 0);
        assertEq(hook.genesis(), block.timestamp);
        assertEq(address(hook.token()), address(token));
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(key.toId()));
        assertEq(hook.quorum(), token.totalSupply() / 100);
        (uint160 price,,,) = pm.getSlot0(key.toId());
        assertEq(price, sqrtPrice);
    }

    function test_deployAgainstAnExistingPoolManager() public {
        PoolManager existing = new PoolManager(address(this));
        (SurfToken token, BuyOnlyVoteHook hook, IPoolManager pm) = script.deploy(config(0, address(existing), 0));
        assertEq(address(pm), address(existing));
        assertEq(address(hook.poolManager()), address(existing));
        assertEq(address(hook.token()), address(token));
        assertEq(hook.genesis(), block.timestamp);
    }

    function test_noStrayPoolCanBindTheHookAfterTheScriptRan() public {
        (, BuyOnlyVoteHook hook, IPoolManager pm) = script.deploy(config(31337, address(0), 0));
        MockERC20 stray = new MockERC20("Stray", "STRAY", 1e24);
        PoolKey memory strayKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(stray)),
            fee: 0,
            tickSpacing: 60,
            hooks: IHooks(address(hook))
        });
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BuyOnlyVoteHook.AlreadyInitialized.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        pm.initialize(strayKey, sqrtPrice);
    }

    function test_refusesAPredictedHookAddressThatAlreadyHasCode() public {
        PoolManager existing = new PoolManager(address(this));
        (, BuyOnlyVoteHook first,) = script.deploy(config(0, address(existing), 0));
        // Same manager, same creation code, same salt search: the first address found is taken.
        vm.expectRevert(abi.encodeWithSelector(Deploy.HookAddressTaken.selector, address(first)));
        script.deploy(config(0, address(existing), 0));
        // The reverted run left its broadcast open in the cheatcode state; close it before the next run.
        vm.stopBroadcast();
        // Starting the search further along finds a free address.
        (, BuyOnlyVoteHook second,) = script.deploy(config(0, address(existing), 1_000_000));
        assertTrue(address(second) != address(first));
        assertEq(HookFlags.flagsOf(address(second)), script.HOOK_FLAGS());
    }

    function test_rejectsChainIdMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainIdMismatch.selector, 11155111, 31337));
        script.deploy(config(11155111, address(1), 0));
    }

    function test_rejectsUnsupportedChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        script.deploy(config(0, address(1), 0));
    }

    function test_sepoliaRequiresAPoolManagerAddress() public {
        vm.chainId(11155111);
        vm.expectRevert(Deploy.PoolManagerRequired.selector);
        script.deploy(config(11155111, address(0), 0));
    }
}
