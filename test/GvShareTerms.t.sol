// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvShareTerms } from "../src/GvShareTerms.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract GvShareTermsTest is Test {
    uint256 internal constant PRICE = 1_000_000;

    GvShare internal share;
    GvCompanyRules internal rules;
    GvShareTerms internal terms;
    MockERC20 internal usdc;

    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal buyer = makeAddr("buyer");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        share = new GvShare("Example Shares", "EXS", 0, issuer, 100, address(this));
        rules = new GvCompanyRules(address(this));
        terms = new GvShareTerms(address(this), share, rules, address(usdc));
    }

    function test_receipt_requires_the_current_sha_and_the_whitelist() public {
        _distribute();
        terms.publishSha(keccak256("sha-v1"), "bafybeiplaceholder");
        terms.setWhitelist(issuer, true);
        terms.setWhitelist(alice, true);
        terms.setPreEmptionEnabled(false);
        share.setTransferPolicy(address(terms));

        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.NotWhitelisted.selector);
        share.transfer(bob, 1);
        terms.setWhitelist(bob, true);

        vm.prank(alice);
        terms.acceptSha();
        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.ShaNotAccepted.selector);
        share.transfer(bob, 1);

        vm.prank(bob);
        terms.acceptSha();
        vm.prank(issuer);
        share.transfer(bob, 1);
        assertEq(share.balanceOf(bob), 25);

        terms.publishSha(keccak256("sha-v2"), "bafybeinext");
        assertEq(terms.shaVersion(), 2);
        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.ShaNotAccepted.selector);
        share.transfer(bob, 1);
        vm.prank(bob);
        terms.acceptSha();
        vm.prank(issuer);
        share.transfer(bob, 1);
        assertEq(share.balanceOf(bob), 26);
        assertEq(terms.acceptedVersion(bob), 2);
    }

    function test_lockup_blocks_a_peer_transfer_until_it_expires() public {
        _distribute();
        _openPeers();
        terms.setLockup(issuer, uint64(block.timestamp) + 10 days);
        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.Locked.selector);
        share.transfer(alice, 1);
        vm.warp(block.timestamp + 10 days);
        vm.prank(issuer);
        share.transfer(alice, 1);
        assertEq(share.balanceOf(alice), 37);
    }

    function test_preemption_offers_existing_holders_a_pro_rata_window() public {
        _distribute();
        _openPeers();
        terms.setPreEmptionEnabled(true);
        _fund(alice);
        _fund(bob);
        _fund(buyer);

        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.PreEmptionRequired.selector);
        share.transfer(buyer, 10);

        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.UseTagAlong.selector);
        terms.startPreEmption(buyer, 40, PRICE);

        vm.prank(issuer);
        share.approve(address(terms), 10);
        vm.prank(issuer);
        uint256 id = terms.startPreEmption(buyer, 10, PRICE);
        // Seller held 40. Base is the other 60. Alice 36 can take 6. Bob 24 can take 4.
        assertEq(terms.preEmption(id).baseSupply, 60);

        vm.prank(bob);
        vm.expectPartialRevert(GvShareTerms.CapExceeded.selector);
        terms.exercisePreEmption(id, 5);
        vm.prank(alice);
        terms.exercisePreEmption(id, 6);
        vm.prank(bob);
        terms.exercisePreEmption(id, 2);

        vm.expectPartialRevert(GvShareTerms.WindowOpen.selector);
        terms.settlePreEmption(id);
        vm.warp(terms.preEmption(id).deadline + 1);
        terms.settlePreEmption(id);

        assertEq(share.balanceOf(alice), 42);
        assertEq(share.balanceOf(bob), 26);
        assertEq(share.balanceOf(buyer), 2);
        assertEq(share.balanceOf(address(terms)), 0);
        vm.prank(issuer);
        terms.withdrawProceeds(address(usdc));
        assertEq(usdc.balanceOf(issuer), 10 * PRICE);
    }

    function _distribute() internal {
        vm.prank(issuer);
        share.transfer(alice, 36);
        vm.prank(issuer);
        share.transfer(bob, 24);
    }

    function _openPeers() internal {
        terms.publishSha(keccak256("sha-v1"), "bafybeiplaceholder");
        terms.setWhitelist(issuer, true);
        terms.setWhitelist(alice, true);
        terms.setWhitelist(bob, true);
        terms.setWhitelist(buyer, true);
        terms.setPreEmptionEnabled(false);
        share.setTransferPolicy(address(terms));
        vm.prank(issuer);
        terms.acceptSha();
        vm.prank(alice);
        terms.acceptSha();
        vm.prank(bob);
        terms.acceptSha();
        vm.prank(buyer);
        terms.acceptSha();
    }

    function _fund(address account) internal {
        usdc.mint(account, 100 * PRICE);
        vm.prank(account);
        usdc.approve(address(terms), type(uint256).max);
    }
}
