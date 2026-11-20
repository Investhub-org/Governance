// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvShareTerms } from "../src/GvShareTerms.sol";
import { MerkleBuilder } from "./MerkleBuilder.sol";
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

    function test_treasury_and_mints_skip_preemption_and_keep_the_other_checks() public {
        _distribute();
        _openPeers();
        terms.setPreEmptionEnabled(true);
        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.PreEmptionRequired.selector);
        share.transfer(alice, 1);

        terms.setIssuerTreasury(issuer);
        vm.expectEmit(true, true, false, true, address(terms));
        emit GvShareTerms.PrimaryIssuance(issuer, alice, 1, false);
        vm.prank(issuer);
        share.transfer(alice, 1);
        assertEq(share.balanceOf(alice), 37);

        vm.prank(alice);
        vm.expectPartialRevert(GvShareTerms.PreEmptionRequired.selector);
        share.transfer(bob, 1);

        vm.expectEmit(true, true, false, true, address(terms));
        emit GvShareTerms.PrimaryIssuance(address(0), bob, 2, true);
        share.mint(bob, 2);
        assertEq(share.balanceOf(bob), 26);

        terms.setLockup(issuer, uint64(block.timestamp) + 1 days);
        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.Locked.selector);
        share.transfer(alice, 1);

        terms.setWhitelist(buyer, false);
        vm.expectPartialRevert(GvShareTerms.NotWhitelisted.selector);
        share.mint(buyer, 1);
    }

    function test_batch_whitelist_merkle_acceptance_and_eip712_relay() public {
        terms.publishSha(keccak256("sha-v1"), "bafybeiplaceholder");
        address[] memory accounts = new address[](2);
        accounts[0] = alice;
        accounts[1] = bob;
        terms.setWhitelistBatch(accounts, true);
        assertTrue(terms.whitelisted(alice) && terms.whitelisted(bob));

        bytes32[] memory leaves = new bytes32[](2);
        uint256 version = terms.shaVersion();
        bytes32 hash = terms.shaHash();
        leaves[0] = keccak256(bytes.concat(keccak256(abi.encode(alice, version, hash))));
        leaves[1] = keccak256(bytes.concat(keccak256(abi.encode(bob, version, hash))));
        bytes32[][] memory tree = MerkleBuilder.build(leaves);
        terms.setShaAcceptanceRoot(MerkleBuilder.root(tree));
        bytes32[][] memory proofs = new bytes32[][](2);
        proofs[0] = MerkleBuilder.proof(tree, 0);
        proofs[1] = MerkleBuilder.proof(tree, 1);
        terms.acceptShaWithProofBatch(accounts, proofs);
        assertTrue(terms.holdsCurrentSha(alice));
        assertTrue(terms.holdsCurrentSha(bob));
        assertEq(terms.acceptedVersion(alice), version);

        bytes32[] memory bad = new bytes32[](1);
        bad[0] = bytes32(uint256(1));
        vm.expectRevert(abi.encodeWithSelector(GvShareTerms.BadProof.selector, buyer));
        terms.acceptShaWithProof(buyer, bad);

        uint256 key = 0xA11CE;
        address signer = vm.addr(key);
        terms.setWhitelist(signer, true);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(key, terms.acceptanceDigest(signer));
        address[] memory signed = new address[](1);
        bytes[] memory signatures = new bytes[](1);
        signed[0] = signer;
        signatures[0] = abi.encodePacked(r, s, v);
        terms.acceptShaBySigBatch(signed, signatures);
        assertTrue(terms.holdsCurrentSha(signer));

        terms.publishSha(keccak256("sha-v2"), "bafybeinext");
        assertFalse(terms.holdsCurrentSha(signer));
        assertEq(terms.shaAcceptanceRoot(), bytes32(0));
        vm.expectRevert(abi.encodeWithSelector(GvShareTerms.BadSignature.selector, signer));
        terms.acceptShaBySig(signer, signatures[0]);

        address[] memory empty = new address[](0);
        vm.expectPartialRevert(GvShareTerms.BatchBounds.selector);
        terms.setWhitelistBatch(empty, true);
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
