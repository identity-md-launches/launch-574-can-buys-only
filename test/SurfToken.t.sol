// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {SurfToken} from "../src/SurfToken.sol";

contract SurfTokenTest is Test {
    SurfToken token;
    address deployer = makeAddr("deployer");

    function setUp() public {
        vm.prank(deployer);
        token = new SurfToken();
    }

    function test_metadata() public view {
        assertEq(token.name(), "Surf");
        assertEq(token.symbol(), "SURF");
        assertEq(token.decimals(), 18);
    }

    function test_mintsExactlyOneBillionToTheDeployer() public view {
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
    }

    function test_transferMovesExactlyTheAmount() public {
        address to = makeAddr("to");
        vm.prank(deployer);
        assertTrue(token.transfer(to, 1_000e18));
        assertEq(token.balanceOf(to), 1_000e18);
        assertEq(token.balanceOf(deployer), token.totalSupply() - 1_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferMoreThanBalanceReverts() public {
        address to = makeAddr("to");
        vm.prank(to);
        vm.expectRevert();
        token.transfer(deployer, 1);
    }

    function test_noMintOrAdminEntryPoints() public {
        string[6] memory signatures = [
            "mint(address,uint256)",
            "mint(uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "upgradeTo(address)"
        ];
        for (uint256 i = 0; i < signatures.length; i++) {
            vm.prank(deployer);
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], deployer, uint256(1)));
            assertFalse(ok, signatures[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function testFuzz_transfer(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        vm.prank(deployer);
        token.transfer(to, amount);
        assertEq(token.balanceOf(to), amount);
        assertEq(token.balanceOf(deployer) + amount, token.totalSupply());
    }
}
