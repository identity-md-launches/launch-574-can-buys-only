// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {SurfToken} from "../src/SurfToken.sol";
import {BuyOnlyVoteHook} from "../src/BuyOnlyVoteHook.sol";
import {HookFlags} from "../src/HookFlags.sol";

contract DeployTest is Test {
    Deploy script;
    address c2;

    function setUp() public {
        script = new Deploy();
        c2 = script.CREATE2_DEPLOYER();
    }

    function test_deployLocallyWithAFreshPoolManager() public {
        (SurfToken token, BuyOnlyVoteHook hook, IPoolManager pm) =
            script.deploy(Deploy.Config({expectedChainId: 31337, poolManager: address(0), create2Deployer: c2}));
        assertTrue(address(pm).code.length > 0);
        assertEq(address(hook.poolManager()), address(pm));
        assertEq(HookFlags.flagsOf(address(hook)), script.HOOK_FLAGS());
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(hook.genesis(), 0, "the pool is initialized by the launch, not the script");
    }

    function test_deployAgainstAnExistingPoolManager() public {
        PoolManager existing = new PoolManager(address(this));
        (, BuyOnlyVoteHook hook, IPoolManager pm) =
            script.deploy(Deploy.Config({expectedChainId: 0, poolManager: address(existing), create2Deployer: c2}));
        assertEq(address(pm), address(existing));
        assertEq(address(hook.poolManager()), address(existing));
    }

    function test_rejectsChainIdMismatch() public {
        vm.expectRevert(abi.encodeWithSelector(Deploy.ChainIdMismatch.selector, 11155111, 31337));
        script.deploy(Deploy.Config({expectedChainId: 11155111, poolManager: address(1), create2Deployer: c2}));
    }

    function test_rejectsUnsupportedChain() public {
        vm.chainId(1);
        vm.expectRevert(abi.encodeWithSelector(Deploy.UnsupportedChain.selector, 1));
        script.deploy(Deploy.Config({expectedChainId: 0, poolManager: address(1), create2Deployer: c2}));
    }

    function test_sepoliaRequiresAPoolManagerAddress() public {
        vm.chainId(11155111);
        vm.expectRevert(Deploy.PoolManagerRequired.selector);
        script.deploy(Deploy.Config({expectedChainId: 11155111, poolManager: address(0), create2Deployer: c2}));
    }
}
