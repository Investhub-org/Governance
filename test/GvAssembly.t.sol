// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { Test } from "forge-std/Test.sol";
import { GvAssembly } from "../src/GvAssembly.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvInformation } from "../src/GvInformation.sol";
import { GvShare } from "../src/GvShare.sol";

contract GvAssemblyTest is Test {
    bytes32 internal constant INVITATION = keccak256("invitation-pdf");
    string internal constant CID = "bafybeiplaceholder";

    GvShare internal share;
    GvGovernor internal governor;
    GvCompanyRules internal rules;
    GvAssembly internal assemblyGv;
    GvInformation internal info;

    address internal issuer = makeAddr("issuer");
    address internal director = makeAddr("director");
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        share = new GvShare("Example Shares", "EXS", 0, issuer, 100, address(this));
        address[] memory empty = new address[](0);
        TimelockController timelock = new TimelockController(1, empty, empty, address(this));
        governor = new GvGovernor("Example Governor", share, timelock, 1, 3600, 1, 4);
        rules = new GvCompanyRules(address(this));
        assemblyGv = new GvAssembly(address(this), share, rules, governor);
        info = new GvInformation(share, rules, assemblyGv);
    }

    function test_egm_convened_by_the_board_emits_an_invitation_and_waits_out_notice() public {
        assemblyGv.setDirector(director, true);
        vm.prank(issuer);
        share.transfer(alice, 100);
        assertEq(share.balanceOf(director), 0);

        GvAssembly.AgendaItem[] memory agenda = _one("Remove a director", GvCompanyRules.ResolutionClass.Ordinary);
        uint64 deadline = uint64(block.timestamp) + rules.noticePeriod(GvCompanyRules.MeetingType.EGM);
        bytes32 agendaHash = assemblyGv.hashAgenda(agenda);

        vm.expectEmit(true, true, true, true, address(assemblyGv));
        emit GvAssembly.InvitationNotice(
            1, uint8(GvCompanyRules.MeetingType.EGM), director, true, deadline, INVITATION, CID, agendaHash
        );
        vm.prank(director);
        uint256 id = assemblyGv.conveneByBoard(GvCompanyRules.MeetingType.EGM, INVITATION, CID, agenda);

        GvAssembly.Meeting memory meeting = assemblyGv.meeting(id);
        assertEq(uint8(meeting.meetingType), uint8(GvCompanyRules.MeetingType.EGM));
        assertEq(meeting.convener, director);
        assertTrue(meeting.convenedByBoard);
        assertEq(meeting.noticeDeadline, deadline);
        assertEq(meeting.invitationHash, INVITATION);
        assertEq(meeting.invitationCid, CID);
        assertEq(meeting.agendaHash, agendaHash);
        assertEq(assemblyGv.agendaLength(id), 1);
        assertEq(assemblyGv.agendaItem(id, 0).title, "Remove a director");

        vm.expectRevert(abi.encodeWithSelector(GvAssembly.NoticeNotElapsed.selector, id, deadline));
        assemblyGv.openMeeting(id);
        vm.warp(deadline);
        assemblyGv.openMeeting(id);
        assertEq(uint8(assemblyGv.meeting(id).phase), uint8(GvAssembly.Phase.Open));
    }

    function test_egm_convened_by_a_shareholder_above_the_threshold() public {
        vm.prank(issuer);
        share.transfer(alice, 10);
        vm.prank(issuer);
        share.transfer(bob, 9);
        vm.prank(alice);
        share.delegate(alice);
        vm.prank(bob);
        share.delegate(bob);
        vm.warp(block.timestamp + 1);

        vm.prank(bob);
        vm.expectPartialRevert(GvAssembly.ThresholdNotMet.selector);
        assemblyGv.conveneByShareholders(
            GvCompanyRules.MeetingType.EGM, INVITATION, CID, _one("Agenda", GvCompanyRules.ResolutionClass.Ordinary)
        );

        vm.prank(alice);
        uint256 id = assemblyGv.conveneByShareholders(
            GvCompanyRules.MeetingType.EGM, INVITATION, CID, _one("Capital", GvCompanyRules.ResolutionClass.Qualified)
        );
        GvAssembly.Meeting memory meeting = assemblyGv.meeting(id);
        assertFalse(meeting.convenedByBoard);
        assertEq(meeting.convener, alice);
        assertEq(uint8(meeting.meetingType), uint8(GvCompanyRules.MeetingType.EGM));
        assertEq(uint8(assemblyGv.agendaItem(id, 0).class), uint8(GvCompanyRules.ResolutionClass.Qualified));
    }

    function test_support_is_a_votes_snapshot_and_does_not_double_count() public {
        vm.prank(issuer);
        share.transfer(alice, 6);
        vm.prank(issuer);
        share.transfer(bob, 6);
        vm.prank(alice);
        share.delegate(alice);
        vm.prank(bob);
        share.delegate(bob);
        vm.warp(block.timestamp + 1);

        vm.prank(alice);
        uint256 requestId = assemblyGv.fileConveningRequest(
            GvCompanyRules.MeetingType.EGM,
            INVITATION,
            CID,
            _one("Information", GvCompanyRules.ResolutionClass.Ordinary)
        );
        vm.prank(alice);
        assemblyGv.supportConveningRequest(requestId);
        vm.prank(alice);
        share.transfer(stranger, 6);
        vm.prank(stranger);
        vm.expectPartialRevert(GvAssembly.NoShares.selector);
        assemblyGv.supportConveningRequest(requestId);
        assertEq(assemblyGv.supportOf(requestId), 6);
        assertTrue(assemblyGv.hasSupported(requestId, alice));

        vm.prank(bob);
        assemblyGv.supportConveningRequest(requestId);
        uint256 id = assemblyGv.conveneFromRequest(requestId);
        assertEq(assemblyGv.supportOf(requestId), 12);
        assertEq(share.balanceOf(alice), 0);
        assertEq(assemblyGv.meeting(id).convener, alice);
        assertFalse(assemblyGv.meeting(id).convenedByBoard);
        assertEq(assemblyGv.request(requestId).meetingId, id);
    }

    function test_convening_support_scales_past_sixty_four_holders() public {
        uint256 supporters = 70;
        for (uint256 i; i < supporters; ++i) {
            address account = address(uint160(0xA000 + i));
            vm.prank(issuer);
            share.transfer(account, 1);
            vm.prank(account);
            share.delegate(account);
        }
        vm.warp(block.timestamp + 1);
        address first = address(uint160(0xA000));
        vm.prank(first);
        uint256 requestId = assemblyGv.fileConveningRequest(
            GvCompanyRules.MeetingType.EGM, INVITATION, CID, _one("Scale", GvCompanyRules.ResolutionClass.Ordinary)
        );
        for (uint256 i; i < supporters; ++i) {
            vm.prank(address(uint160(0xA000 + i)));
            assemblyGv.supportConveningRequest(requestId);
        }
        assertEq(assemblyGv.supportOf(requestId), supporters);
        uint256 id = assemblyGv.conveneFromRequest(requestId);
        assertEq(assemblyGv.meeting(id).convener, first);
        assertFalse(assemblyGv.meeting(id).convenedByBoard);
    }

    function test_agm_uses_its_own_notice_and_a_short_board_cannot_convene() public {
        GvCompanyRules.CapitalBand[] memory bands = new GvCompanyRules.CapitalBand[](1);
        bands[0] = GvCompanyRules.CapitalBand({ capitalAtOrAbove: 1_000_000, minDirectors: 3 });
        rules.setCapitalBands(bands);
        rules.setShareCapital(1_000_000, "CHF");
        assemblyGv.setDirector(director, true);

        vm.prank(director);
        vm.expectPartialRevert(GvAssembly.BoardBelowMinimum.selector);
        assemblyGv.conveneByBoard(
            GvCompanyRules.MeetingType.AGM, INVITATION, CID, _one("Accounts", GvCompanyRules.ResolutionClass.Ordinary)
        );

        rules.setShareCapital(0, "CHF");
        vm.prank(director);
        uint256 id = assemblyGv.conveneByBoard(
            GvCompanyRules.MeetingType.AGM, INVITATION, CID, _one("Accounts", GvCompanyRules.ResolutionClass.Ordinary)
        );
        assertEq(
            assemblyGv.meeting(id).noticeDeadline - assemblyGv.meeting(id).convenedAt,
            rules.noticePeriod(GvCompanyRules.MeetingType.AGM)
        );
        assertEq(uint8(assemblyGv.meeting(id).meetingType), uint8(GvCompanyRules.MeetingType.AGM));
    }

    function test_articles_outcome_uses_the_resolution_class() public {
        vm.prank(issuer);
        share.transfer(alice, 60);
        vm.prank(issuer);
        share.transfer(bob, 40);
        _delegate(alice);
        _delegate(bob);

        GvAssembly.AgendaItem[] memory agenda = new GvAssembly.AgendaItem[](2);
        agenda[0] = GvAssembly.AgendaItem({
            title: "Ordinary", documentHash: keccak256("ordinary"), class: GvCompanyRules.ResolutionClass.Ordinary
        });
        agenda[1] = GvAssembly.AgendaItem({
            title: "Statute", documentHash: keccak256("statute"), class: GvCompanyRules.ResolutionClass.Qualified
        });
        assemblyGv.setDirector(director, true);
        vm.prank(director);
        uint256 meetingId = assemblyGv.conveneByBoard(GvCompanyRules.MeetingType.EGM, INVITATION, CID, agenda);
        vm.warp(assemblyGv.meeting(meetingId).noticeDeadline);
        assemblyGv.openMeeting(meetingId);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GovernorSettings.setVotingDelay, (uint48(2)));
        vm.prank(alice);
        uint256 proposalId = governor.propose(targets, values, calldatas, "Class check");
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 0);
        vm.warp(governor.proposalDeadline(proposalId) + 1);

        vm.prank(alice);
        assemblyGv.bindProposal(meetingId, 0, proposalId);
        vm.prank(alice);
        assemblyGv.bindProposal(meetingId, 1, proposalId);

        GvCompanyRules.ResolutionOutcome memory ordinary = assemblyGv.articlesOutcome(meetingId, 0, proposalId);
        GvCompanyRules.ResolutionOutcome memory qualified = assemblyGv.articlesOutcome(meetingId, 1, proposalId);
        assertEq(qualified.forVotes, 60);
        assertEq(qualified.againstVotes, 40);
        assertTrue(ordinary.articlesQuorum);
        assertTrue(ordinary.articlesMajority);
        assertTrue(ordinary.passed);
        assertTrue(qualified.articlesQuorum);
        assertFalse(qualified.articlesMajority);
        assertTrue(qualified.bravoQuorum);
        assertTrue(qualified.bravoMajority);
        assertFalse(qualified.passed);

        rules.setBindingMode(GvCompanyRules.BindingMode.Governor);
        qualified = assemblyGv.articlesOutcome(meetingId, 1, proposalId);
        assertTrue(qualified.passed);
        rules.setBindingMode(GvCompanyRules.BindingMode.Both);
        qualified = assemblyGv.articlesOutcome(meetingId, 1, proposalId);
        assertFalse(qualified.passed);
    }

    function test_a_flash_loan_cannot_convene() public {
        vm.prank(issuer);
        share.transfer(alice, 1);
        vm.prank(alice);
        share.delegate(alice);
        vm.warp(block.timestamp + 1);

        address attacker = makeAddr("flash-borrower");
        vm.prank(issuer);
        share.transfer(attacker, 50);
        vm.prank(attacker);
        share.delegate(attacker);
        vm.prank(attacker);
        vm.expectPartialRevert(GvAssembly.ThresholdNotMet.selector);
        assemblyGv.conveneByShareholders(
            GvCompanyRules.MeetingType.EGM, INVITATION, CID, _one("Borrowed", GvCompanyRules.ResolutionClass.Ordinary)
        );

        vm.warp(block.timestamp + 1);
        vm.prank(attacker);
        uint256 id = assemblyGv.conveneByShareholders(
            GvCompanyRules.MeetingType.EGM,
            INVITATION,
            CID,
            _one("After the checkpoint", GvCompanyRules.ResolutionClass.Ordinary)
        );
        assertEq(assemblyGv.meeting(id).convener, attacker);
    }

    function test_execution_obeys_articles_unless_binding_mode_is_governor() public {
        governor.recognizeIssuer(issuer);
        vm.prank(issuer);
        governor.setArticlesGate(address(assemblyGv));
        TimelockController timelock = TimelockController(payable(governor.timelock()));
        timelock.grantRole(timelock.PROPOSER_ROLE(), address(governor));
        timelock.grantRole(timelock.EXECUTOR_ROLE(), address(governor));

        vm.prank(issuer);
        share.transfer(alice, 60);
        vm.prank(issuer);
        share.transfer(bob, 40);
        _delegate(alice);
        _delegate(bob);

        GvAssembly.AgendaItem[] memory agenda = new GvAssembly.AgendaItem[](4);
        agenda[0] = GvAssembly.AgendaItem({
            title: "Ordinary", documentHash: keccak256("ordinary"), class: GvCompanyRules.ResolutionClass.Ordinary
        });
        agenda[1] = GvAssembly.AgendaItem({
            title: "Statute", documentHash: keccak256("statute"), class: GvCompanyRules.ResolutionClass.Qualified
        });
        agenda[2] = GvAssembly.AgendaItem({
            title: "Ordinary again",
            documentHash: keccak256("ordinary-again"),
            class: GvCompanyRules.ResolutionClass.Ordinary
        });
        agenda[3] = GvAssembly.AgendaItem({
            title: "Statute again",
            documentHash: keccak256("statute-again"),
            class: GvCompanyRules.ResolutionClass.Qualified
        });
        assemblyGv.setDirector(director, true);
        vm.prank(director);
        uint256 meetingId = assemblyGv.conveneByBoard(GvCompanyRules.MeetingType.EGM, INVITATION, CID, agenda);
        vm.warp(assemblyGv.meeting(meetingId).noticeDeadline);
        assemblyGv.openMeeting(meetingId);

        uint256 ordinaryId = _classProposal("Ordinary execution");
        _voteSplit(ordinaryId);
        assertEq(uint8(assemblyGv.executionClass(ordinaryId)), uint8(GvCompanyRules.ResolutionClass.Qualified));
        vm.prank(alice);
        assemblyGv.bindProposal(meetingId, 0, ordinaryId);
        assertEq(uint8(assemblyGv.executionClass(ordinaryId)), uint8(GvCompanyRules.ResolutionClass.Ordinary));
        _queue(ordinaryId, "Ordinary execution");
        _execute(ordinaryId, "Ordinary execution");
        assertEq(uint256(governor.state(ordinaryId)), uint256(IGovernor.ProposalState.Executed));

        uint256 qualifiedId = _classProposal("Qualified execution");
        _voteSplit(qualifiedId);
        vm.prank(alice);
        assemblyGv.bindProposal(meetingId, 1, qualifiedId);
        vm.prank(bob);
        assemblyGv.bindProposal(meetingId, 2, qualifiedId);
        assertEq(uint8(assemblyGv.executionClass(qualifiedId)), uint8(GvCompanyRules.ResolutionClass.Qualified));
        _queue(qualifiedId, "Qualified execution");
        vm.warp(governor.proposalEta(qualifiedId));
        vm.expectPartialRevert(GvAssembly.ArticlesNotPassed.selector);
        _executeNow(qualifiedId, "Qualified execution");
        assertEq(uint256(governor.state(qualifiedId)), uint256(IGovernor.ProposalState.Queued));

        rules.setBindingMode(GvCompanyRules.BindingMode.Governor);
        _executeNow(qualifiedId, "Qualified execution");
        assertEq(uint256(governor.state(qualifiedId)), uint256(IGovernor.ProposalState.Executed));

        rules.setBindingMode(GvCompanyRules.BindingMode.Both);
        uint256 bothId = _classProposal("Both execution");
        _voteSplit(bothId);
        vm.prank(alice);
        assemblyGv.bindProposal(meetingId, 3, bothId);
        _queue(bothId, "Both execution");
        vm.warp(governor.proposalEta(bothId));
        vm.expectPartialRevert(GvAssembly.ArticlesNotPassed.selector);
        _executeNow(bothId, "Both execution");
    }

    function test_information_request_starts_a_clock_and_overdue_items_are_queryable() public {
        assemblyGv.setDirector(director, true);
        vm.prank(issuer);
        share.transfer(alice, 1);

        vm.prank(stranger);
        vm.expectPartialRevert(GvInformation.NotShareholder.selector);
        info.fileRequest(keccak256("topic"), "Annual report");

        vm.prank(alice);
        uint256 requestId = info.fileRequest(keccak256("topic"), "Annual report");
        assertEq(info.request(requestId).responseDeadline, uint64(block.timestamp) + rules.responseWindow());
        assertFalse(info.isRequestOverdue(requestId));

        bytes32 kind = keccak256("ANNUAL_REPORT");
        vm.prank(director);
        uint256 dutyId = info.schedulePublication(kind, uint64(block.timestamp) + 10);
        vm.warp(block.timestamp + 11);
        (uint256[] memory duties, uint256 nextDuty) = info.overduePublications(0, 10);
        (uint256[] memory requests,) = info.overdueRequests(0, 10);
        assertEq(duties.length, 1);
        assertEq(duties[0], dutyId);
        assertEq(nextDuty, info.dutyCount() + 1);
        assertEq(requests.length, 0);

        vm.warp(info.request(requestId).responseDeadline + 1);
        (requests,) = info.overdueRequests(0, 10);
        assertEq(requests.length, 1);
        assertEq(requests[0], requestId);
        vm.expectEmit(true, true, false, true, address(info));
        emit GvInformation.ResponseOverdue(requestId, alice, info.request(requestId).responseDeadline);
        info.notifyResponseOverdue(requestId);

        bytes32 answer = keccak256("ciphertext-of-the-answer");
        vm.prank(director);
        info.answerRequest(requestId, answer, CID);
        assertFalse(info.isRequestOverdue(requestId));
        assertEq(info.request(requestId).answerHash, answer);
        assertTrue(info.request(requestId).late);
        assertEq(info.request(requestId).answerCid, CID);

        vm.prank(director);
        info.fulfillPublication(dutyId, keccak256("ciphertext-of-the-report"), CID);
        assertFalse(info.isPublicationOverdue(dutyId));
        assertTrue(info.duty(dutyId).late);
        assertEq(info.duty(dutyId).documentHash, keccak256("ciphertext-of-the-report"));
    }

    function _proposalCall()
        internal
        view
        returns (address[] memory targets, uint256[] memory values, bytes[] memory calldatas)
    {
        targets = new address[](1);
        targets[0] = address(governor);
        values = new uint256[](1);
        calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GovernorSettings.setVotingDelay, (uint48(2)));
    }

    function _classProposal(string memory description) internal returns (uint256 proposalId) {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalCall();
        vm.prank(alice);
        proposalId = governor.propose(targets, values, calldatas, description);
    }

    function _voteSplit(uint256 proposalId) internal {
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(alice);
        governor.castVote(proposalId, 1);
        vm.prank(bob);
        governor.castVote(proposalId, 0);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
    }

    function _queue(uint256 proposalId, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalCall();
        governor.queue(targets, values, calldatas, keccak256(bytes(description)));
        proposalId;
    }

    function _execute(uint256 proposalId, string memory description) internal {
        vm.warp(governor.proposalEta(proposalId));
        _executeNow(proposalId, description);
    }

    function _executeNow(uint256 proposalId, string memory description) internal {
        (address[] memory targets, uint256[] memory values, bytes[] memory calldatas) = _proposalCall();
        governor.execute(targets, values, calldatas, keccak256(bytes(description)));
        proposalId;
    }

    function _delegate(address account) internal {
        vm.prank(account);
        share.delegate(account);
        vm.warp(block.timestamp + 1);
    }

    function _one(string memory title, GvCompanyRules.ResolutionClass class)
        internal
        pure
        returns (GvAssembly.AgendaItem[] memory agenda)
    {
        agenda = new GvAssembly.AgendaItem[](1);
        agenda[0] = GvAssembly.AgendaItem({ title: title, documentHash: keccak256(bytes(title)), class: class });
    }
}
