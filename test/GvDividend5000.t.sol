// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { console2 } from "forge-std/console2.sol";
import { GvDividend } from "../src/GvDividend.sol";
import { MerkleBuilder } from "./MerkleBuilder.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";
import { KitFixture } from "./KitFixture.sol";

/// @notice 5,000-holder dividend. On-chain work is the root, one bitmap bit, and one transfer per claim.
contract GvDividend5000Test is KitFixture {
    uint256 internal constant HOLDERS = 5000;
    uint256 internal constant AMOUNT = 1_000_000;

    address internal issuer = makeAddr("issuer");

    GvDividend internal dividend;
    MockERC20 internal usdc;
    uint256 internal epoch;
    address[] internal holders;
    bytes32[][] internal levels;

    function test_five_thousand_holders_claim_in_constant_gas() public {
        (,,, dividend) = _deploy(issuer, _nativeSpec(1), _govSpec(1, 4), bytes32(uint256(5000)));
        usdc = new MockERC20("USD Coin", "USDC", 6);
        (holders, levels) = _build(dividend);

        bytes32 root = MerkleBuilder.root(levels);
        uint256 total = HOLDERS * AMOUNT;
        uint64 deadline = uint64(block.timestamp + 30 days);

        uint256 startGas = gasleft();
        vm.prank(dividend.timelock());
        epoch = dividend.startDistribution(address(usdc), root, total, deadline, "ipfs://5000");
        uint256 startUsed = startGas - gasleft();

        usdc.mint(issuer, total);
        vm.startPrank(issuer);
        usdc.approve(address(dividend), total);
        uint256 fundGas = gasleft();
        dividend.fund(epoch, total);
        uint256 fundUsed = fundGas - gasleft();
        vm.stopPrank();

        // External calls so each proof's memory is discarded. Gas is the claim, measured inside.
        uint256 gasFirst = this.claimAt(0);
        uint256 gasBoundary = this.claimAt(256);
        uint256 gasLast = this.claimAt(HOLDERS - 1);

        for (uint256 i = 1; i < HOLDERS - 1; ++i) {
            if (i == 256) continue;
            this.claimAt(i);
        }

        assertEq(usdc.balanceOf(address(dividend)), 0);
        assertEq(dividend.reserved(address(usdc)), 0);
        (,,, uint256 funded, uint256 claimed,,,) = dividend.distribution(epoch);
        assertEq(funded, total);
        assertEq(claimed, total);

        bytes32[] memory again = MerkleBuilder.proof(levels, 0);
        vm.expectRevert(abi.encodeWithSelector(GvDividend.AlreadyClaimed.selector, epoch, uint256(0)));
        dividend.claim(epoch, 0, holders[0], AMOUNT, again);

        console2.log("startDistribution gas", startUsed);
        console2.log("fund gas", fundUsed);
        console2.log("claim gas index 0", gasFirst);
        console2.log("claim gas index 256", gasBoundary);
        console2.log("claim gas index 4999", gasLast);

        assertLt(startUsed, 250_000, "starting an epoch must not grow with holder count");
        assertLt(gasFirst, 120_000);
        assertLt(gasBoundary, 120_000);
        assertLt(gasLast, 120_000);
        uint256 spread = gasFirst > gasLast ? gasFirst - gasLast : gasLast - gasFirst;
        assertLt(spread, 20_000, "claim gas stays flat from the first holder to the last");
    }

    /// @dev Called externally so each proof is built in its own memory frame.
    /// Reads one sibling per level from storage. It does not copy the tree.
    function claimAt(uint256 index) external returns (uint256 used) {
        bytes32[] memory proof = _proof(index);
        uint256 before = gasleft();
        dividend.claim(epoch, index, holders[index], AMOUNT, proof);
        used = before - gasleft();
    }

    function _proof(uint256 index) internal view returns (bytes32[] memory) {
        bytes32[] memory buf = new bytes32[](levels.length - 1);
        uint256 count;
        uint256 idx = index;
        for (uint256 d; d + 1 < levels.length; ++d) {
            uint256 sibling = idx ^ 1;
            if (sibling < levels[d].length) {
                buf[count++] = levels[d][sibling];
            }
            idx /= 2;
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buf[i];
        }
        return out;
    }

    function _build(GvDividend token) internal pure returns (address[] memory accounts, bytes32[][] memory tree) {
        accounts = new address[](HOLDERS);
        bytes32[] memory leaves = new bytes32[](HOLDERS);
        for (uint256 i; i < HOLDERS; ++i) {
            accounts[i] = address(uint160(0xA000 + i));
            leaves[i] = token.hashLeaf(i, accounts[i], AMOUNT);
        }
        tree = MerkleBuilder.build(leaves);
    }
}
