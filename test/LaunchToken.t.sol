// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchToken} from "../src/LaunchToken.sol";

contract LaunchTokenTest is Test {
    LaunchToken internal token;
    address internal deployer = address(this);
    address internal bob = makeAddr("bob");

    function setUp() public {
        token = new LaunchToken();
    }

    function test_metadataAndSupply() public view {
        assertEq(token.name(), "Pact");
        assertEq(token.symbol(), "PACT");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1_000_000_000e18);
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(deployer), token.totalSupply());
    }

    function test_transferMovesExactAmount() public {
        uint256 amount = 1234e18;
        assertTrue(token.transfer(bob, amount));
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.balanceOf(deployer), token.totalSupply() - amount);
        assertEq(token.totalSupply(), 10 ** 27);
    }

    function test_transferRevertsOnInsufficientBalance() public {
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, 0, 1));
        token.transfer(deployer, 1);
    }

    function test_transferToZeroReverts() public {
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
    }

    function test_transferFromRespectsAllowance() public {
        token.approve(bob, 50);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, 50, 51));
        token.transferFrom(deployer, bob, 51);

        vm.prank(bob);
        assertTrue(token.transferFrom(deployer, bob, 50));
        assertEq(token.allowance(deployer, bob), 0);
        assertEq(token.balanceOf(bob), 50);
    }

    function test_infiniteAllowanceIsNotDecremented() public {
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        token.transferFrom(deployer, bob, 1e18);
        assertEq(token.allowance(deployer, bob), type(uint256).max);
    }

    function test_noAdminEntrypointsChangeSupply() public {
        string[6] memory sigs = [
            "mint(address,uint256)",
            "burn(uint256)",
            "transferOwnership(address)",
            "pause()",
            "setFee(uint256)",
            "upgradeTo(address)"
        ];
        for (uint256 i; i < sigs.length; ++i) {
            vm.prank(bob);
            (bool ok,) = address(token).call(abi.encodeWithSignature(sigs[i], bob, uint256(1)));
            assertFalse(ok, sigs[i]);
        }
        assertEq(token.totalSupply(), 10 ** 27);
        assertEq(token.balanceOf(bob), 0);
    }

    function testFuzz_transferConservesSupply(address to, uint256 amount) public {
        vm.assume(to != address(0) && to != deployer);
        amount = bound(amount, 0, token.totalSupply());
        token.transfer(to, amount);
        assertEq(token.balanceOf(to) + token.balanceOf(deployer), token.totalSupply());
    }
}
