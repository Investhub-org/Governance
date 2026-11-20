// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { stdJson } from "forge-std/StdJson.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { InvestorBook } from "../script/lifecycle/InvestorBook.sol";
import { LifecycleSim } from "../script/lifecycle/LifecycleSim.sol";
import { MerkleBuilder } from "./MerkleBuilder.sol";

/// @notice CI runs 32 holders. The 5,000-holder path is opt-in. The Base fork runs only when
/// `BASE_RPC_URL` is set, and it does not move canonical USDC.
contract LifecycleTest is LifecycleSim {
    using stdJson for string;

    /// @dev Circle FiatToken proxy on Base. Read for the fork smoke check. No transfer is sent here.
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function test_lifecycle_ci() public {
        simulate(32);
        assertEq(holderCount, 32);
        assertGt(totalGas, 0);
        assertTrue(acquisition.drag(dragId).executed);
        assertEq(acquisition.drag(dragId).buyer, InvestorBook.role("tag-buyer"));
        assertGt(acquisition.drag(dragId).buyerHeldAtPost, 250_000);
    }

    function test_lifecycle_five_thousand() public {
        uint256 holders = vm.envOr("SIM_HOLDERS", uint256(0));
        if (holders < 5000) {
            vm.skip(true, "set SIM_HOLDERS=5000 to run the full book");
            return;
        }
        simulate(5000);
        assertEq(holderCount, 5000);
    }

    function testFork_lifecycle_on_base() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL is not set");
            return;
        }
        vm.createSelectFork(rpc);
        assertEq(block.chainid, 8453);
        assertEq(IERC20Metadata(BASE_USDC).symbol(), "USDC");
        assertEq(IERC20Metadata(BASE_USDC).decimals(), 6);
        simulate(16);
        assertTrue(acquisition.drag(dragId).executed);
        assertEq(acquisition.drag(dragId).buyer, InvestorBook.role("tag-buyer"));
    }

    function test_book_matches_offchain_fixture() public view {
        string memory json = vm.readFile("sim/fixtures/book-32.json");
        assertEq(json.readUint(".holders"), 32);
        assertEq(json.readUint(".supply"), InvestorBook.SUPPLY);
        assertEq(json.readUint(".price"), InvestorBook.PRICE);
        assertEq(json.readUint(".dividendPerShare"), InvestorBook.DIVIDEND_PER_SHARE);
        assertEq(json.readBytes32(".shaHash"), keccak256(bytes(vm.readFile("sim/fixtures/sha.txt"))));
        assertEq(json.readBytes32(".annualReportHash"), keccak256(bytes(vm.readFile("sim/fixtures/annual-report.txt"))));
        assertEq(json.readAddress(".roles.issuer"), InvestorBook.role("issuer"));
        assertEq(json.readAddress(".roles.director"), InvestorBook.role("director"));
        assertEq(json.readAddress(".roles.preBuyer"), InvestorBook.role("pre-buyer"));
        assertEq(json.readAddress(".roles.tagBuyer"), InvestorBook.role("tag-buyer"));
        assertEq(json.readAddress(".roles.dragBuyer"), InvestorBook.role("drag-buyer"));
        assertEq(json.readAddress(".roles.investhub"), InvestorBook.role("investhub"));
        assertEq(json.readAddress(".roles.observer"), InvestorBook.role("observer"));

        uint256[] memory shares = InvestorBook.allocate(32);
        bytes32[] memory leaves = new bytes32[](32);
        for (uint256 index; index < 32; ++index) {
            string memory base = string.concat(".investors[", vm.toString(index), "]");
            address account = InvestorBook.investor(index);
            assertEq(json.readAddress(string.concat(base, ".address")), account);
            assertEq(json.readUint(string.concat(base, ".shares")), shares[index]);
            assertEq(json.readUint(string.concat(base, ".dividend")), InvestorBook.dividendOf(shares[index]));
            assertEq(json.readUint(string.concat(base, ".commitment")), shares[index] * InvestorBook.PRICE);
            leaves[index] =
                keccak256(bytes.concat(keccak256(abi.encode(index, account, InvestorBook.dividendOf(shares[index])))));
        }
        bytes32[][] memory tree = MerkleBuilder.build(leaves);
        assertEq(MerkleBuilder.root(tree), json.readBytes32(".root"));

        uint256[4] memory sample = [uint256(0), 1, 16, 31];
        for (uint256 index; index < sample.length; ++index) {
            string memory proofKey = string.concat(".sampleProofs[", vm.toString(index), "]");
            assertEq(json.readUint(string.concat(proofKey, ".index")), sample[index]);
            bytes32[] memory expected = json.readBytes32Array(string.concat(proofKey, ".proof"));
            bytes32[] memory got = MerkleBuilder.proof(tree, sample[index]);
            assertEq(got.length, expected.length);
            for (uint256 leaf; leaf < got.length; ++leaf) {
                assertEq(got[leaf], expected[leaf]);
            }
        }
    }
}
