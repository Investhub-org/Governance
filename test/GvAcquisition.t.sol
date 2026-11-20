// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { GvAcquisition } from "../src/GvAcquisition.sol";
import { GvAssembly } from "../src/GvAssembly.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvRecovery } from "../src/GvRecovery.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvShareTerms } from "../src/GvShareTerms.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract GvAcquisitionTest is Test {
    uint256 internal constant PRICE = 1_000_000;

    GvShare internal share;
    GvCompanyRules internal rules;
    GvShareTerms internal terms;
    GvAcquisition internal acquisition;
    GvRecovery internal recovery;
    MockERC20 internal usdc;
    TimelockController internal timelock;

    address internal issuer = makeAddr("issuer");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal cara = makeAddr("cara");
    address internal buyer = makeAddr("buyer");
    address internal director = makeAddr("director");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        usdc = new MockERC20("USD Coin", "USDC", 6);
        share = new GvShare("Example Shares", "EXS", 0, issuer, 100, address(this));
        rules = new GvCompanyRules(address(this));
        address[] memory empty = new address[](0);
        timelock = new TimelockController(1, empty, empty, address(this));
        GvGovernor governor = new GvGovernor("Example Governor", share, timelock, 1, 3600, 1, 4);
        GvAssembly assemblyGv = new GvAssembly(address(this), share, rules, governor);
        terms = new GvShareTerms(address(this), share, rules, address(usdc));
        acquisition = new GvAcquisition(share, rules, terms);
        recovery = new GvRecovery(share, rules, terms, assemblyGv, address(timelock));
        terms.setAcquisition(address(acquisition));
        assemblyGv.setDirector(director, true);
    }

    function test_drag_converts_every_holder_at_the_same_price_once_quorum_accepts() public {
        _give(buyer, 25);
        _give(alice, 25);
        _give(bob, 25);
        _give(cara, 25);
        _arm();
        _approveSale(alice);
        _approveSale(bob);
        _approveSale(cara);
        _fund(buyer, address(acquisition), 100 * PRICE);

        uint16 quorum = rules.dragQuorumBps();
        uint64 deadline = uint64(block.timestamp) + 7 days;
        vm.prank(buyer);
        uint256 id = acquisition.postDrag(PRICE, deadline, quorum);
        vm.prank(alice);
        acquisition.acceptDrag(id, 25);
        vm.prank(bob);
        acquisition.acceptDrag(id, 25);
        vm.prank(cara);
        acquisition.acceptDrag(id, 25);
        assertEq(acquisition.drag(id).quorumReachedAt, uint64(block.timestamp));

        vm.prank(buyer);
        vm.expectPartialRevert(GvAcquisition.QuorumAlreadyReached.selector);
        acquisition.cancelDrag(id);
        acquisition.executeDrag(id);
        acquisition.claimDrag(id, alice);
        address[] memory rest = new address[](2);
        rest[0] = bob;
        rest[1] = cara;
        assertEq(acquisition.pushDrag(id, rest), 2);
        acquisition.refundDragSurplus(id);

        assertEq(share.balanceOf(buyer), 100);
        assertEq(share.totalSupply(), 100);
        _withdraw(alice, address(acquisition));
        _withdraw(bob, address(acquisition));
        _withdraw(cara, address(acquisition));
        _withdraw(buyer, address(acquisition));
        assertEq(usdc.balanceOf(alice), 25 * PRICE);
        assertEq(usdc.balanceOf(bob), 25 * PRICE);
        assertEq(usdc.balanceOf(cara), 25 * PRICE);
        assertEq(usdc.balanceOf(buyer), 25 * PRICE);
    }

    function test_large_buyer_counts_toward_quorum_and_cannot_inflate_it() public {
        _give(buyer, 30);
        _give(alice, 45);
        _give(bob, 25);
        _arm();
        _approveSale(alice);
        _fund(buyer, address(acquisition), 100 * PRICE);

        vm.prank(buyer);
        uint256 id = acquisition.postDrag(PRICE, uint64(block.timestamp) + 7 days, 7500);
        vm.prank(buyer);
        vm.expectRevert(abi.encodeWithSelector(GvAcquisition.BuyerCannotAccept.selector, buyer));
        acquisition.acceptDrag(id, 1);

        vm.prank(alice);
        acquisition.acceptDrag(id, 44);
        vm.expectPartialRevert(GvAcquisition.QuorumNotReached.selector);
        acquisition.executeDrag(id);

        vm.prank(alice);
        acquisition.acceptDrag(id, 1);
        (uint256 counted, uint256 requiredShares, uint256 buyerCounted_) = acquisition.dragQuorumProgress(id);
        assertEq(buyerCounted_, 30);
        assertEq(counted, 75);
        assertEq(requiredShares, 75);
        acquisition.executeDrag(id);
        assertTrue(acquisition.blocksPeerTransfers());
        vm.prank(bob);
        vm.expectPartialRevert(GvShareTerms.TransferWindowOpen.selector);
        share.transfer(alice, 1);

        acquisition.claimDrag(id, alice);
        acquisition.claimDrag(id, bob);
        assertEq(share.balanceOf(buyer), 100);
        assertEq(acquisition.proceeds(bob, address(usdc)), 25 * PRICE);
    }

    function test_recovery_cannot_move_shares_onto_the_buyer_during_a_drag() public {
        _give(buyer, 40);
        _give(alice, 30);
        _give(bob, 30);
        _arm();
        _fund(buyer, address(acquisition), 100 * PRICE);
        vm.prank(buyer);
        uint256 id = acquisition.postDrag(PRICE, uint64(block.timestamp) + 90 days, 7500);
        assertTrue(acquisition.dragUnsettled());

        vm.prank(director);
        uint256 recoveryId = recovery.proposeRecovery(alice, buyer, 30, keccak256("inflate"), false);
        vm.warp(recovery.recovery(recoveryId).executeAfter);
        vm.expectPartialRevert(GvRecovery.DragUnsettled.selector);
        recovery.executeRecovery(recoveryId);

        (uint256 counted,, uint256 buyerCounted_) = acquisition.dragQuorumProgress(id);
        assertEq(share.balanceOf(buyer), 40);
        assertEq(share.balanceOf(alice), 30);
        assertEq(buyerCounted_, 40);
        assertEq(counted, 40);
        vm.prank(buyer);
        acquisition.cancelDrag(id);
        assertFalse(acquisition.dragUnsettled());
        recovery.executeRecovery(recoveryId);
        assertEq(share.balanceOf(buyer), 70);
        assertEq(share.balanceOf(alice), 0);
    }

    function test_recovery_cannot_move_shares_off_the_buyer_during_a_drag() public {
        _give(buyer, 80);
        _give(alice, 20);
        _arm();
        _fund(buyer, address(acquisition), 100 * PRICE);
        vm.prank(buyer);
        uint256 id = acquisition.postDrag(PRICE, uint64(block.timestamp) + 90 days, 7500);
        assertGt(acquisition.drag(id).quorumReachedAt, 0);

        vm.prank(director);
        uint256 courtId = recovery.proposeRecovery(buyer, stranger, 1, keccak256("court-during-drag"), true);
        vm.prank(director);
        uint256 recoveryId = recovery.proposeRecovery(buyer, alice, 60, keccak256("deflate"), false);
        vm.warp(recovery.recovery(recoveryId).executeAfter);
        vm.expectPartialRevert(GvRecovery.DragUnsettled.selector);
        recovery.executeRecovery(courtId);
        vm.expectPartialRevert(GvRecovery.DragUnsettled.selector);
        recovery.executeRecovery(recoveryId);
        vm.prank(buyer);
        vm.expectPartialRevert(GvAcquisition.QuorumAlreadyReached.selector);
        acquisition.cancelDrag(id);
        assertEq(share.balanceOf(buyer), 80);

        acquisition.executeDrag(id);
        vm.expectPartialRevert(GvRecovery.DragUnsettled.selector);
        recovery.executeRecovery(recoveryId);
        acquisition.claimDrag(id, alice);
        assertFalse(acquisition.dragUnsettled());
        recovery.executeRecovery(recoveryId);
        assertEq(share.balanceOf(buyer), 40);
        assertEq(share.balanceOf(alice), 60);
        vm.prank(director);
        recovery.cancelRecovery(courtId);
    }

    function test_unclaimed_drag_proceeds_redirect_after_the_window() public {
        _give(buyer, 80);
        _give(alice, 20);
        _arm();
        _fund(buyer, address(acquisition), 100 * PRICE);
        vm.prank(buyer);
        uint256 id = acquisition.postDrag(PRICE, uint64(block.timestamp) + 7 days, 7500);
        acquisition.executeDrag(id);

        address[] memory tooMany = new address[](33);
        vm.expectPartialRevert(GvAcquisition.BatchBounds.selector);
        acquisition.pushDrag(id, tooMany);

        vm.expectPartialRevert(GvAcquisition.UnclaimedRecipientUnset.selector);
        acquisition.redirectUnclaimed(id, alice);
        rules.setUnclaimedRecipient(stranger);
        vm.warp(uint256(acquisition.drag(id).executedAt) + rules.unclaimedWindow());
        vm.expectPartialRevert(GvAcquisition.TooEarly.selector);
        acquisition.redirectUnclaimed(id, alice);
        vm.warp(block.timestamp + 1);
        acquisition.redirectUnclaimed(id, alice);

        assertEq(share.balanceOf(buyer), 100);
        assertEq(share.balanceOf(alice), 0);
        assertEq(acquisition.proceeds(alice, address(usdc)), 0);
        assertEq(acquisition.proceeds(stranger, address(usdc)), 20 * PRICE);
        acquisition.refundDragSurplus(id);
        _withdraw(stranger, address(acquisition));
        _withdraw(buyer, address(acquisition));
        assertEq(usdc.balanceOf(stranger), 20 * PRICE);
        assertEq(usdc.balanceOf(buyer), 80 * PRICE);
    }

    function test_drag_below_quorum_refunds_the_buyer_and_returns_shares() public {
        _give(alice, 100);
        _arm();
        _approveSale(alice);
        _fund(buyer, address(acquisition), 100 * PRICE);
        vm.prank(buyer);
        uint256 id = acquisition.postDrag(PRICE, uint64(block.timestamp) + 2 days, 7500);
        vm.prank(alice);
        acquisition.acceptDrag(id, 10);
        vm.expectPartialRevert(GvAcquisition.QuorumNotReached.selector);
        acquisition.executeDrag(id);
        vm.prank(stranger);
        vm.expectPartialRevert(GvAcquisition.NotBuyer.selector);
        acquisition.cancelDrag(id);
        vm.warp(block.timestamp + 2 days + 1);
        acquisition.cancelDrag(id);
        vm.prank(alice);
        acquisition.reclaimDrag(id);
        _withdraw(buyer, address(acquisition));
        assertEq(share.balanceOf(alice), 100);
        assertEq(usdc.balanceOf(buyer), 100 * PRICE);
    }

    function test_tag_along_same_price_and_recovery_are_not_an_admin_key() public {
        rules.setTagThreshold(2000);
        vm.prank(issuer);
        share.transfer(alice, 50);
        vm.prank(issuer);
        share.transfer(bob, 50);
        _arm();
        _approveSale(alice);
        _approveSale(bob);
        _fund(buyer, address(acquisition), 100 * PRICE);

        vm.prank(alice);
        vm.expectPartialRevert(GvAcquisition.BelowTagThreshold.selector);
        acquisition.openTagSale(buyer, 10, PRICE, uint64(block.timestamp) + 3 days);

        vm.prank(alice);
        share.approve(address(terms), 50);
        vm.prank(alice);
        vm.expectPartialRevert(GvShareTerms.UseTagAlong.selector);
        terms.startPreEmption(buyer, 40, PRICE);

        vm.prank(alice);
        uint256 id = acquisition.openTagSale(buyer, 25, PRICE, uint64(block.timestamp) + 3 days);
        assertEq(acquisition.tag(id).maxJoin, 25);
        vm.prank(bob);
        vm.expectPartialRevert(GvAcquisition.CapExceeded.selector);
        acquisition.joinTag(id, 26);
        vm.prank(bob);
        acquisition.joinTag(id, 25);
        vm.expectPartialRevert(GvAcquisition.TooEarly.selector);
        acquisition.settleTag(id);
        vm.warp(acquisition.tag(id).deadline + 1);
        acquisition.settleTag(id);
        vm.prank(bob);
        acquisition.claimTag(id);

        assertEq(share.balanceOf(buyer), 50);
        assertEq(share.balanceOf(alice), 25);
        assertEq(share.balanceOf(bob), 25);
        _withdraw(alice, address(acquisition));
        _withdraw(bob, address(acquisition));
        assertEq(usdc.balanceOf(alice), 25 * PRICE);
        assertEq(usdc.balanceOf(bob), 25 * PRICE);

        vm.prank(address(acquisition));
        vm.expectPartialRevert(GvShare.ForceNotAuthorized.selector);
        share.moduleTransfer(alice, buyer, 1);
    }

    function test_recovery_waits_and_a_court_order_is_not_a_holder_veto() public {
        vm.prank(issuer);
        share.transfer(alice, 10);
        _arm();

        vm.prank(stranger);
        vm.expectPartialRevert(GvRecovery.NotDirector.selector);
        recovery.proposeRecovery(alice, bob, 4, keccak256("minutes"), false);
        vm.prank(director);
        vm.expectRevert(GvRecovery.MissingHash.selector);
        recovery.proposeRecovery(alice, bob, 4, bytes32(0), false);

        vm.prank(director);
        uint256 boardId = recovery.proposeRecovery(alice, bob, 4, keccak256("board-minutes"), false);
        uint64 when = recovery.recovery(boardId).executeAfter;
        vm.warp(when - 1);
        vm.expectPartialRevert(GvRecovery.TooEarly.selector);
        recovery.executeRecovery(boardId);
        vm.prank(alice);
        recovery.cancelRecovery(boardId);
        vm.warp(when);
        vm.expectPartialRevert(GvRecovery.RecoveryClosed.selector);
        recovery.executeRecovery(boardId);

        vm.prank(director);
        uint256 courtId = recovery.proposeRecovery(alice, stranger, 0, keccak256("court-order"), true);
        vm.prank(alice);
        vm.expectRevert(GvRecovery.HolderCannotCancelCourtOrder.selector);
        recovery.cancelRecovery(courtId);
        vm.prank(address(timelock));
        recovery.cancelRecovery(courtId);

        vm.prank(director);
        courtId = recovery.proposeRecovery(alice, stranger, 0, keccak256("court-order-2"), true);
        vm.warp(recovery.recovery(courtId).executeAfter);
        recovery.executeRecovery(courtId);
        assertEq(share.balanceOf(stranger), 10);
        assertEq(share.balanceOf(alice), 0);

        vm.prank(stranger);
        vm.expectPartialRevert(GvShare.NotShareModule.selector);
        share.moduleTransfer(bob, stranger, 1);
    }

    function test_recovery_can_require_a_second_director() public {
        vm.prank(issuer);
        share.transfer(alice, 5);
        _arm();
        rules.setRecoverySignatures(2);
        address second = makeAddr("second-director");
        // The assembly in setUp is not stored. Use a recovery that reads the same assembly.
        // Director appointments live on the assembly the recovery was constructed with.
        // Re-read it through a new handle: the recovery exposes assembly_.
        recovery.assembly_().setDirector(second, true);

        vm.prank(director);
        uint256 id = recovery.proposeRecovery(alice, bob, 5, keccak256("minutes"), false);
        vm.warp(recovery.recovery(id).executeAfter);
        vm.expectPartialRevert(GvRecovery.NeedSignatures.selector);
        recovery.executeRecovery(id);
        vm.prank(second);
        recovery.cosignRecovery(id);
        recovery.executeRecovery(id);
        assertEq(share.balanceOf(bob), 5);
    }

    function _give(address to, uint256 amount) internal {
        if (amount == 0) return;
        vm.prank(issuer);
        share.transfer(to, amount);
    }

    function _arm() internal {
        terms.publishSha(keccak256("sha-v1"), "bafybeiplaceholder");
        address[6] memory accounts = [issuer, alice, bob, cara, buyer, stranger];
        for (uint256 i; i < accounts.length; ++i) {
            if (accounts[i] == address(0)) continue;
            terms.setWhitelist(accounts[i], true);
            vm.prank(accounts[i]);
            terms.acceptSha();
        }
        terms.setWhitelist(bob, true);
        share.setTransferPolicy(address(terms));
        share.setShareModule(address(acquisition), true);
        share.setShareModule(address(recovery), true);
    }

    function _approveSale(address account) internal {
        vm.prank(account);
        share.approve(address(acquisition), type(uint256).max);
    }

    function _fund(address account, address spender, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.prank(account);
        usdc.approve(spender, type(uint256).max);
    }

    function _withdraw(address account, address escrow) internal {
        vm.prank(account);
        GvAcquisition(escrow).withdrawProceeds(address(usdc));
    }
}
