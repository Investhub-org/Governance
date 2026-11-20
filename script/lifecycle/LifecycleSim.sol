// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { GvAcquisition } from "../../src/GvAcquisition.sol";
import { GvAssembly } from "../../src/GvAssembly.sol";
import { GvCompanyRules } from "../../src/GvCompanyRules.sol";
import { GvDirectory } from "../../src/GvDirectory.sol";
import { GvDividend } from "../../src/GvDividend.sol";
import { GvGovernor } from "../../src/GvGovernor.sol";
import { GvInformation } from "../../src/GvInformation.sol";
import { GvKitFactory } from "../../src/GvKitFactory.sol";
import { GvRecovery } from "../../src/GvRecovery.sol";
import { GvShare } from "../../src/GvShare.sol";
import { GvShareTerms } from "../../src/GvShareTerms.sol";
import {
    GvDividendDeployer,
    GvGovernorDeployer,
    GvShareDeployer,
    GvTimelockDeployer,
    GvVotesWrapperDeployer
} from "../../src/deployers/GvDeployers.sol";
import { MerkleBuilder } from "../../test/MerkleBuilder.sol";
import { MockERC20 } from "../../test/mocks/MockERC20.sol";
import { InvestorBook } from "./InvestorBook.sol";

/// @notice One issuer's company, from CREATE2 deployment through a drag-along.
/// InvestHub is an address in the book and is never given a role. Governor delays are compressed so the
/// run can finish locally. Assembly notice, pre-emption, tag, and the information window stay on the
/// placeholder values in {GvCompanyRules} and are crossed with `vm.warp`.
///
/// Gas figures are the execution gas of each call, before refunds, inside one Foundry transaction.
/// A later call sees warm accounts. They do not include the 21,000 intrinsic transaction cost.
contract LifecycleSim is Test {
    string internal constant CID = "bafybeiplaceholder";
    string internal constant METADATA = "ipfs://gv-sim-lifecycle";
    string internal constant DIVIDEND_URI = "ipfs://gv-sim-dividend";
    string internal constant DESC_TERMS = "Adopt the share terms and arm acquisition and recovery";
    string internal constant DESC_REPORT = "Approve the annual report";
    string internal constant DESC_DIVIDEND = "Approve the dividend";
    string internal constant DESC_EGM = "Appoint an observer";
    string internal constant TOPIC = "Share register extract";

    address internal issuer;
    address internal director;
    address internal preBuyer;
    address internal tagBuyer;
    address internal dragBuyer;
    address internal hub;
    address internal observer;
    address internal recovered;
    address internal reserve;

    GvKitFactory internal factory;
    GvDirectory internal directory;
    GvShare internal share;
    GvGovernor internal governor;
    TimelockController internal timelock;
    GvDividend internal dividend;
    GvCompanyRules internal rules;
    GvAssembly internal assemblyGv;
    GvInformation internal info;
    GvShareTerms internal terms;
    GvAcquisition internal acquisition;
    GvRecovery internal recovery;
    MockERC20 internal usdc;

    uint256 public holderCount;
    uint256 public totalGas;
    bytes32 public dividendRoot;
    address[] internal investors;
    uint256[] internal book;
    bytes32[][] internal levels;

    bytes32 internal shaHash;
    bytes32 internal reportHash;
    uint256 internal dividendTotal;
    uint64 internal dividendDeadline;
    uint256 internal dividendEpoch;
    uint256 internal agmId;
    uint256 internal egmId;
    uint256 internal termsProposal;
    uint256 internal reportProposal;
    uint256 internal dividendProposal;
    uint256 internal egmProposal;
    uint256 internal dutyId;
    uint256 internal requestId;
    uint256 internal preEmptionId;
    uint256 internal tagId;
    uint256 internal dragId;
    uint256 internal conveningRequestId;
    uint256 internal recoveryId;

    string internal phaseName;
    uint256 internal phaseGas;

    function simulate(uint256 holders) public {
        uint256 started = vm.unixTime();
        uint256 startedGas = gasleft();
        holderCount = holders;
        _roles();
        _loadBook();
        shaHash = keccak256(bytes(vm.readFile("sim/fixtures/sha.txt")));
        reportHash = keccak256(bytes(vm.readFile("sim/fixtures/annual-report.txt")));

        _begin("deploy");
        _deployInfrastructure();
        _deployKit();
        _deployTerms();

        _begin("issue");
        _publishAndWhitelist();
        _accept();
        _armPolicy();
        _distribute();
        _delegateFounders();
        _buildTree();

        _begin("agm");
        _handover();
        _agm();

        _begin("dividend");
        _fundAndClaim();

        _begin("egm");
        _egm();

        _begin("information");
        _information();

        _begin("recovery");
        _recovery();

        _begin("preemption");
        _preEmption();

        _begin("tag");
        _tag();

        _begin("drag");
        _drag();
        _flush();

        console2.log("TOTAL", totalGas);
        console2.log("simulate gas", startedGas - gasleft());
        console2.log("runtime ms", vm.unixTime() - started);
        console2.log("holders", holderCount);
        console2.log("investor0", investors[0]);
        console2.log("dividend root");
        console2.logBytes32(dividendRoot);

        _assertFinal();
        _assertIndependence();
    }

    function _roles() internal {
        issuer = InvestorBook.role("issuer");
        director = InvestorBook.role("director");
        preBuyer = InvestorBook.role("pre-buyer");
        tagBuyer = InvestorBook.role("tag-buyer");
        dragBuyer = InvestorBook.role("drag-buyer");
        hub = InvestorBook.role("investhub");
        observer = InvestorBook.role("observer");
        recovered = InvestorBook.role("recovered-holder");
        reserve = InvestorBook.role("unclaimed-reserve");
    }

    function _loadBook() internal {
        book = InvestorBook.allocate(holderCount);
        investors = new address[](holderCount);
        for (uint256 index; index < holderCount; ++index) {
            investors[index] = InvestorBook.investor(index);
            assertTrue(investors[index] != issuer && investors[index] != hub);
            assertTrue(investors[index] != preBuyer && investors[index] != tagBuyer);
            assertTrue(investors[index] != dragBuyer && investors[index] != director);
            assertTrue(investors[index] != recovered && investors[index] != reserve);
        }
        assertEq(book[0], 320_000);
        assertEq(book[1], 180_000);
        assertEq(book[2], 120_000);
        assertEq(book[3], 100_000);
        assertEq(book[4], 80_000);
    }

    function _deployInfrastructure() internal {
        vm.startPrank(issuer);
        uint256 nonce = vm.getNonce(issuer);
        address predicted = vm.computeCreateAddress(issuer, nonce + 5);
        uint256 gasUsed;
        new GvShareDeployer(predicted);
        gasUsed = _gas();
        new GvVotesWrapperDeployer(predicted);
        gasUsed += _gas();
        new GvTimelockDeployer(predicted);
        gasUsed += _gas();
        new GvGovernorDeployer(predicted);
        gasUsed += _gas();
        new GvDividendDeployer(predicted);
        gasUsed += _gas();
        factory = new GvKitFactory(
            GvShareDeployer(vm.computeCreateAddress(issuer, nonce)),
            GvVotesWrapperDeployer(vm.computeCreateAddress(issuer, nonce + 1)),
            GvTimelockDeployer(vm.computeCreateAddress(issuer, nonce + 2)),
            GvGovernorDeployer(vm.computeCreateAddress(issuer, nonce + 3)),
            GvDividendDeployer(vm.computeCreateAddress(issuer, nonce + 4))
        );
        gasUsed += _gas();
        directory = new GvDirectory();
        gasUsed += _gas();
        vm.stopPrank();
        assertEq(address(factory), predicted);
        _add("infrastructure", gasUsed);
    }

    function _deployKit() internal {
        GvKitFactory.ShareSpec memory shareSpec = GvKitFactory.ShareSpec({
            name: "Simulated Holdings",
            symbol: "SIM",
            decimals: 0,
            initialSupply: InvestorBook.SUPPLY,
            existingUnderlying: address(0),
            existingVotesToken: address(0)
        });
        GvKitFactory.GovSpec memory govSpec = GvKitFactory.GovSpec({
            name: "Simulated Holdings Governor",
            votingDelay: 1,
            votingPeriod: 3600,
            proposalThreshold: 1,
            quorumNumerator: 4,
            timelockDelay: 1
        });
        (address predictedShare, address predictedGov, address predictedTimelock, address predictedDividend) =
            factory.predict(issuer, shareSpec, govSpec, InvestorBook.KIT_SALT);
        vm.prank(issuer);
        (address shareAddr, address governorAddr, address timelockAddr, address dividendAddr) =
            factory.deploy(shareSpec, govSpec, METADATA, InvestorBook.KIT_SALT);
        _add("kit deploy", _gas());
        assertEq(shareAddr, predictedShare);
        assertEq(governorAddr, predictedGov);
        assertEq(timelockAddr, predictedTimelock);
        assertEq(dividendAddr, predictedDividend);
        share = GvShare(shareAddr);
        governor = GvGovernor(payable(governorAddr));
        timelock = TimelockController(payable(timelockAddr));
        dividend = GvDividend(dividendAddr);
        assertEq(share.balanceOf(issuer), InvestorBook.SUPPLY);
        assertEq(share.timelock(), timelockAddr);
    }

    function _deployTerms() internal {
        vm.startPrank(issuer);
        usdc = new MockERC20("Simulation USD", "USDC", 6);
        uint256 gasUsed = _gas();
        rules = new GvCompanyRules(issuer);
        gasUsed += _gas();
        assemblyGv = new GvAssembly(issuer, share, rules, governor);
        gasUsed += _gas();
        governor.setArticlesGate(address(assemblyGv));
        gasUsed += _gas();
        info = new GvInformation(share, rules, assemblyGv);
        gasUsed += _gas();
        terms = new GvShareTerms(issuer, share, rules, address(usdc));
        gasUsed += _gas();
        rules.setUnclaimedRecipient(reserve);
        gasUsed += _gas();
        rules.setBindingMode(GvCompanyRules.BindingMode.Articles);
        gasUsed += _gas();
        acquisition = new GvAcquisition(share, rules, terms);
        gasUsed += _gas();
        terms.setAcquisition(address(acquisition));
        gasUsed += _gas();
        recovery = new GvRecovery(share, rules, terms, assemblyGv, address(timelock));
        gasUsed += _gas();
        vm.stopPrank();
        _add("terms stack", gasUsed);
        assertEq(terms.owner(), issuer);
        assertEq(address(acquisition.terms()), address(terms));
    }

    function _publishAndWhitelist() internal {
        vm.startPrank(issuer);
        terms.publishSha(shaHash, CID);
        uint256 gasUsed = _gas();
        assemblyGv.setDirector(director, true);
        gasUsed += _gas();
        assemblyGv.setDirector(address(timelock), true);
        gasUsed += _gas();
        terms.setIssuerTreasury(issuer);
        gasUsed += _gas();
        vm.stopPrank();
        _add("publish SHA and appoint directors", gasUsed);

        address[] memory accounts = _onboardingAccounts();
        (uint256 first, uint256 last, uint256 sum, uint256 batches) = _whitelistBatches(accounts);
        _add("whitelist batch", sum);
        console2.log("whitelist batches", batches);
        console2.log("whitelist batch first", first);
        console2.log("whitelist batch last", last);
        console2.log("whitelist per account", sum / accounts.length);
        assertTrue(terms.whitelisted(investors[holderCount - 1]));
        assertTrue(terms.whitelisted(recovered));
        assertFalse(terms.whitelisted(hub));
    }

    function _accept() internal {
        address[] memory accounts = _onboardingAccounts();
        bytes32[] memory leaves = new bytes32[](accounts.length);
        uint256 version = terms.shaVersion();
        bytes32 hash = terms.shaHash();
        for (uint256 index; index < accounts.length; ++index) {
            leaves[index] = keccak256(bytes.concat(keccak256(abi.encode(accounts[index], version, hash))));
        }
        bytes32[][] memory tree = MerkleBuilder.build(leaves);
        vm.prank(issuer);
        terms.setShaAcceptanceRoot(MerkleBuilder.root(tree));
        _add("SHA acceptance root", _gas());

        (uint256 first, uint256 last, uint256 sum, uint256 batches) = _acceptBatches(accounts, tree);
        _add("accept SHA batch", sum);
        console2.log("accept batches", batches);
        console2.log("accept batch first", first);
        console2.log("accept batch last", last);
        console2.log("accept per account", sum / accounts.length);
        assertTrue(terms.holdsCurrentSha(investors[holderCount - 1]));
        assertTrue(terms.holdsCurrentSha(issuer));
        assertTrue(terms.holdsCurrentSha(recovered));
        assertEq(terms.acceptedVersion(investors[0]), version);
    }

    function _distribute() internal {
        uint256 first;
        uint256 last;
        uint256 sum;
        vm.startPrank(issuer);
        for (uint256 index; index < holderCount; ++index) {
            share.transfer(investors[index], book[index]);
            uint256 used = _gas();
            if (index == 0) first = used;
            last = used;
            sum += used;
        }
        vm.stopPrank();
        _add("distribute shares", sum);
        console2.log("distribute first", first);
        console2.log("distribute last", last);
        console2.log("distribute average", sum / holderCount);
        assertEq(share.balanceOf(issuer), 0);
        assertEq(share.balanceOf(investors[0]), book[0]);
        assertEq(share.totalSupply(), InvestorBook.SUPPLY);
        assertEq(share.transferPolicy(), address(terms));
        assertEq(terms.issuerTreasury(), issuer);
        vm.prank(investors[3]);
        vm.expectRevert(GvShareTerms.PreEmptionRequired.selector);
        share.transfer(investors[4], 1);
    }

    function _armPolicy() internal {
        vm.prank(issuer);
        share.delegate(issuer);
        _add("delegate issuer", _gas());
        vm.warp(block.timestamp + 1);

        address[] memory targets = new address[](1);
        targets[0] = address(share);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calls = new bytes[](1);
        calls[0] = abi.encodeCall(GvShare.setTransferPolicy, (address(terms)));
        string memory description = "Turn on the share transfer policy";
        vm.prank(issuer);
        uint256 id = governor.propose(targets, values, calls, description);
        _add("policy propose", _gas());
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(issuer);
        governor.castVote(id, 1);
        _add("policy vote", _gas());
        vm.warp(governor.proposalDeadline(id) + 1);
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calls, descriptionHash);
        _add("policy queue", _gas());
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calls, descriptionHash);
        _add("policy execute", _gas());
        assertEq(share.transferPolicy(), address(terms));
    }

    function _delegateFounders() internal {
        vm.prank(investors[0]);
        share.delegate(investors[0]);
        uint256 gasUsed = _gas();
        vm.prank(investors[1]);
        share.delegate(investors[1]);
        gasUsed += _gas();
        _add("delegate founders", gasUsed);
        vm.warp(block.timestamp + 1);
    }

    function _buildTree() internal {
        bytes32[] memory leaves = new bytes32[](holderCount);
        for (uint256 index; index < holderCount; ++index) {
            leaves[index] = dividend.hashLeaf(index, investors[index], InvestorBook.dividendOf(book[index]));
        }
        levels = MerkleBuilder.build(leaves);
        dividendRoot = MerkleBuilder.root(levels);
        dividendTotal = InvestorBook.SUPPLY * InvestorBook.DIVIDEND_PER_SHARE;
    }

    function _handover() internal {
        vm.prank(issuer);
        directory.register(address(share), address(governor), address(timelock), address(dividend), METADATA);
        uint256 gasUsed = _gas();
        vm.startPrank(issuer);
        rules.transferOwnership(address(timelock));
        gasUsed += _gas();
        terms.transferOwnership(address(timelock));
        gasUsed += _gas();
        assemblyGv.transferOwnership(address(timelock));
        gasUsed += _gas();
        vm.stopPrank();
        _add("directory and ownership handover", gasUsed);
        assertEq(rules.owner(), address(timelock));
        assertEq(terms.owner(), address(timelock));
        assertEq(assemblyGv.owner(), address(timelock));
    }

    function _agm() internal {
        vm.prank(director);
        dutyId = info.schedulePublication(keccak256("annual-report"), uint64(block.timestamp + 90 days));
        _add("schedule annual report", _gas());

        GvAssembly.AgendaItem[] memory agenda = new GvAssembly.AgendaItem[](3);
        agenda[0] = GvAssembly.AgendaItem("Adopt share terms", shaHash, GvCompanyRules.ResolutionClass.Ordinary);
        agenda[1] =
            GvAssembly.AgendaItem("Approve the annual report", reportHash, GvCompanyRules.ResolutionClass.Ordinary);
        agenda[2] = GvAssembly.AgendaItem("Approve the dividend", dividendRoot, GvCompanyRules.ResolutionClass.Ordinary);
        vm.prank(director);
        agmId = assemblyGv.conveneByBoard(GvCompanyRules.MeetingType.AGM, keccak256("sim-agm-invitation"), CID, agenda);
        _add("convene AGM", _gas());
        assertTrue(assemblyGv.meeting(agmId).convenedByBoard);
        vm.warp(assemblyGv.meeting(agmId).noticeDeadline);
        assemblyGv.openMeeting(agmId);
        _add("open AGM", _gas());

        address[] memory voters = _voters(false);
        termsProposal = _conduct(voters, _termsCalls(), DESC_TERMS, "agm terms", agmId, 0);
        reportProposal = _conduct(voters, _reportCalls(), DESC_REPORT, "agm report", agmId, 1);
        dividendDeadline = uint64(block.timestamp + 180 days);
        dividendProposal = _conduct(voters, _dividendCalls(), DESC_DIVIDEND, "agm dividend", agmId, 2);

        vm.prank(director);
        assemblyGv.closeMeeting(agmId);
        _add("close AGM", _gas());

        assertEq(share.transferPolicy(), address(terms));
        assertTrue(share.shareModules(address(acquisition)));
        assertTrue(share.shareModules(address(recovery)));
        assertEq(uint8(governor.state(termsProposal)), uint8(IGovernor.ProposalState.Executed));
        assertEq(info.duty(dutyId).documentHash, reportHash);
        assertFalse(info.duty(dutyId).late);
        assertEq(dividend.distributionCount(), 1);
        dividendEpoch = 0;
        _assertArticles(agmId, 0, termsProposal);
        _assertArticles(agmId, 1, reportProposal);
        _assertArticles(agmId, 2, dividendProposal);

        vm.prank(investors[3]);
        vm.expectRevert(GvShareTerms.PreEmptionRequired.selector);
        share.transfer(investors[4], 1);
    }

    function _fundAndClaim() internal {
        usdc.mint(issuer, dividendTotal);
        vm.prank(issuer);
        usdc.approve(address(dividend), dividendTotal);
        _add("approve dividend funding", _gas());
        vm.prank(issuer);
        dividend.fund(dividendEpoch, dividendTotal);
        _add("fund dividend", _gas());

        uint256[4] memory sample;
        sample[0] = 0;
        sample[1] = 1;
        sample[2] = holderCount / 2;
        sample[3] = holderCount - 1;
        uint256 claimed;
        for (uint256 index; index < sample.length; ++index) {
            uint256 leaf = sample[index];
            uint256 amount = InvestorBook.dividendOf(book[leaf]);
            bytes32[] memory proof = MerkleBuilder.proof(levels, leaf);
            dividend.claim(dividendEpoch, leaf, investors[leaf], amount, proof);
            uint256 used = _gas();
            assertLt(used, 250_000, "claim gas");
            _add(string.concat("claim ", vm.toString(leaf)), used);
            claimed += amount;
            assertEq(usdc.balanceOf(investors[leaf]), amount);
        }
        (,,, uint256 funded, uint256 claimedOnChain,,,) = dividend.distribution(dividendEpoch);
        assertEq(funded, dividendTotal);
        assertEq(claimedOnChain, claimed);
        assertEq(usdc.balanceOf(address(dividend)), dividendTotal - claimed);
    }

    function _egm() internal {
        GvAssembly.AgendaItem[] memory agenda = new GvAssembly.AgendaItem[](1);
        agenda[0] = GvAssembly.AgendaItem(
            "Appoint an observer", keccak256("sim-observer-resolution"), GvCompanyRules.ResolutionClass.Qualified
        );
        vm.prank(investors[0]);
        conveningRequestId = assemblyGv.fileConveningRequest(
            GvCompanyRules.MeetingType.EGM, keccak256("sim-egm-invitation"), CID, agenda
        );
        _add("file convening request", _gas());
        vm.prank(investors[0]);
        assemblyGv.supportConveningRequest(conveningRequestId);
        _add("support convening request", _gas());
        assertGe(assemblyGv.supportOf(conveningRequestId), 100_000);
        egmId = assemblyGv.conveneFromRequest(conveningRequestId);
        _add("convene EGM", _gas());
        assertFalse(assemblyGv.meeting(egmId).convenedByBoard);
        assertEq(assemblyGv.meeting(egmId).convener, investors[0]);
        vm.warp(assemblyGv.meeting(egmId).noticeDeadline);
        assemblyGv.openMeeting(egmId);
        _add("open EGM", _gas());

        egmProposal = _conduct(_voters(true), _egmCalls(), DESC_EGM, "egm observer", egmId, 0);
        _assertArticles(egmId, 0, egmProposal);
        assertTrue(assemblyGv.isDirector(observer));

        vm.prank(investors[0]);
        assemblyGv.closeMeeting(egmId);
        _add("close EGM", _gas());
    }

    function _information() internal {
        bytes32 topicHash = keccak256(bytes(TOPIC));
        uint256 filedAt = block.timestamp;
        vm.prank(investors[holderCount - 1]);
        requestId = info.fileRequest(topicHash, TOPIC);
        _add("file information request", _gas());
        assertEq(info.request(requestId).responseDeadline, uint64(filedAt) + rules.responseWindow());
        assertFalse(info.isRequestOverdue(requestId));

        vm.warp(info.request(requestId).responseDeadline + 1);
        assertTrue(info.isRequestOverdue(requestId));
        info.notifyResponseOverdue(requestId);
        _add("notify response overdue", _gas());

        vm.prank(director);
        info.answerRequest(requestId, keccak256("sim-register-extract"), CID);
        _add("answer information request", _gas());
        assertTrue(info.request(requestId).late);
        assertGt(info.request(requestId).answeredAt, info.request(requestId).responseDeadline);
    }

    function _recovery() internal {
        address from = investors[6];
        uint256 amount = share.balanceOf(from);
        assertGt(amount, 0);
        vm.prank(director);
        recoveryId = recovery.proposeRecovery(from, recovered, amount, keccak256("sim-board-minutes"), false);
        _add("propose recovery", _gas());
        vm.warp(recovery.recovery(recoveryId).executeAfter);
        recovery.executeRecovery(recoveryId);
        _add("execute recovery", _gas());
        assertEq(share.balanceOf(from), 0);
        assertEq(share.balanceOf(recovered), amount);
        assertTrue(recovery.recovery(recoveryId).executed);
        assertEq(recovery.recovery(recoveryId).orderHash, keccak256("sim-board-minutes"));
    }

    function _preEmption() internal {
        address seller = investors[2];
        address exerciser = investors[1];
        vm.prank(seller);
        share.approve(address(terms), InvestorBook.PREEMPTION_AMOUNT);
        _add("approve pre-emption", _gas());
        vm.prank(seller);
        preEmptionId = terms.startPreEmption(preBuyer, InvestorBook.PREEMPTION_AMOUNT, InvestorBook.PRICE);
        _add("open pre-emption", _gas());

        _mintApprove(exerciser, address(terms), InvestorBook.PREEMPTION_EXERCISE * InvestorBook.PRICE);
        vm.prank(exerciser);
        terms.exercisePreEmption(preEmptionId, InvestorBook.PREEMPTION_EXERCISE);
        _add("exercise pre-emption", _gas());

        vm.warp(terms.preEmption(preEmptionId).deadline + 1);
        uint256 remaining = InvestorBook.PREEMPTION_AMOUNT - InvestorBook.PREEMPTION_EXERCISE;
        _mintApprove(preBuyer, address(terms), remaining * InvestorBook.PRICE);
        terms.settlePreEmption(preEmptionId);
        _add("settle pre-emption", _gas());

        assertEq(share.balanceOf(seller), book[2] - InvestorBook.PREEMPTION_AMOUNT);
        assertEq(share.balanceOf(exerciser), book[1] + InvestorBook.PREEMPTION_EXERCISE);
        assertEq(share.balanceOf(preBuyer), remaining);
        assertEq(terms.proceeds(seller, address(usdc)), InvestorBook.PREEMPTION_AMOUNT * InvestorBook.PRICE);
    }

    function _tag() internal {
        address seller = investors[0];
        vm.prank(seller);
        share.approve(address(acquisition), InvestorBook.TAG_STAKE);
        _add("approve tag stake", _gas());

        uint256 sellerBalance = share.balanceOf(seller);
        uint256 maxJoin = (InvestorBook.SUPPLY - sellerBalance) * InvestorBook.TAG_STAKE / sellerBalance;
        _mintApprove(tagBuyer, address(acquisition), (InvestorBook.TAG_STAKE + maxJoin) * InvestorBook.PRICE);
        vm.prank(seller);
        tagId = acquisition.openTagSale(
            tagBuyer, InvestorBook.TAG_STAKE, InvestorBook.PRICE, uint64(block.timestamp + 14 days)
        );
        _add("open tag sale", _gas());
        assertEq(acquisition.tag(tagId).maxJoin, maxJoin);
        assertEq(maxJoin, 637_500);

        vm.prank(investors[1]);
        share.approve(address(acquisition), InvestorBook.TAG_JOIN);
        _add("approve tag join", _gas());
        vm.prank(investors[1]);
        acquisition.joinTag(tagId, InvestorBook.TAG_JOIN);
        _add("join tag sale", _gas());

        vm.warp(acquisition.tag(tagId).deadline + 1);
        acquisition.settleTag(tagId);
        _add("settle tag sale", _gas());
        vm.prank(investors[1]);
        acquisition.claimTag(tagId);
        _add("claim tag sale", _gas());

        assertEq(share.balanceOf(seller), sellerBalance - InvestorBook.TAG_STAKE);
        assertEq(share.balanceOf(tagBuyer), InvestorBook.TAG_STAKE + InvestorBook.TAG_JOIN);
        assertEq(share.balanceOf(investors[1]), book[1] + InvestorBook.PREEMPTION_EXERCISE - InvestorBook.TAG_JOIN);
    }

    function _drag() internal {
        _mintApprove(tagBuyer, address(acquisition), InvestorBook.SUPPLY * InvestorBook.PRICE);
        uint16 dragQuorum = rules.dragQuorumBps();
        vm.prank(tagBuyer);
        dragId = acquisition.postDrag(InvestorBook.PRICE, uint64(block.timestamp + 14 days), dragQuorum);
        _add("post drag", _gas());
        assertEq(acquisition.drag(dragId).buyer, tagBuyer);
        assertEq(acquisition.drag(dragId).buyerHeldAtPost, 301_000);

        address[] memory acceptors = new address[](6);
        acceptors[0] = investors[0];
        acceptors[1] = investors[1];
        acceptors[2] = investors[2];
        acceptors[3] = investors[3];
        acceptors[4] = investors[4];
        acceptors[5] = preBuyer;
        uint256 approveGas;
        uint256 acceptGas;
        uint256 tendered;
        for (uint256 index; index < acceptors.length; ++index) {
            uint256 balance = share.balanceOf(acceptors[index]);
            vm.startPrank(acceptors[index]);
            share.approve(address(acquisition), balance);
            approveGas += _gas();
            acquisition.acceptDrag(dragId, balance);
            acceptGas += _gas();
            vm.stopPrank();
            tendered += balance;
        }
        _add("approve drag tenders", approveGas);
        _add("accept drag", acceptGas);
        assertEq(tendered, 499_000);
        (uint256 counted, uint256 requiredShares, uint256 buyerCounted_) = acquisition.dragQuorumProgress(dragId);
        assertEq(buyerCounted_, 301_000);
        assertEq(counted, 800_000);
        assertEq(requiredShares, 750_000);
        console2.log("drag counted", counted);
        console2.log("drag buyer counted", buyerCounted_);

        acquisition.executeDrag(dragId);
        _add("execute drag", _gas());
        assertTrue(acquisition.drag(dragId).executed);
        assertTrue(acquisition.blocksPeerTransfers());

        address[] memory pulling = new address[](7);
        pulling[0] = investors[0];
        pulling[1] = investors[1];
        pulling[2] = investors[2];
        pulling[3] = investors[3];
        pulling[4] = investors[4];
        pulling[5] = preBuyer;
        pulling[6] = recovered;
        uint256 claimGas;
        for (uint256 index; index < pulling.length; ++index) {
            acquisition.claimDrag(dragId, pulling[index]);
            uint256 used = _gas();
            if (index == 0) console2.log("claim first", used);
            claimGas += used;
        }
        _add("claim drag", claimGas);
        console2.log("claim count", pulling.length);

        uint256 start = 10;
        uint256 lastIndex = holderCount - 1;
        uint256 available = lastIndex > start ? lastIndex - start : 0;
        uint256 n = available > acquisition.MAX_PUSH() ? acquisition.MAX_PUSH() : available;
        if (n > 0) {
            address[] memory batch = new address[](n);
            for (uint256 index; index < n; ++index) {
                batch[index] = investors[start + index];
            }
            uint256 pushed = acquisition.pushDrag(dragId, batch);
            _add("push drag", _gas());
            assertEq(pushed, n);
            console2.log("push count", n);
        }

        vm.prank(investors[7]);
        vm.expectRevert(GvShareTerms.TransferWindowOpen.selector);
        share.transfer(investors[8], 1);

        vm.prank(investors[3]);
        acquisition.withdrawProceeds(address(usdc));
        _add("withdraw sale proceeds", _gas());

        vm.warp(uint256(acquisition.drag(dragId).executedAt) + rules.unclaimedWindow() + 1);
        acquisition.redirectUnclaimed(dragId, investors[holderCount - 1]);
        _add("redirect unclaimed", _gas());
        assertEq(share.balanceOf(investors[holderCount - 1]), 0);
        assertEq(acquisition.proceeds(reserve, address(usdc)), book[holderCount - 1] * InvestorBook.PRICE);
    }

    function _conduct(
        address[] memory voters,
        bytes[] memory calls,
        string memory description,
        string memory label,
        uint256 meetingId,
        uint256 itemIndex
    ) internal returns (uint256 id) {
        address[] memory targets = new address[](calls.length);
        for (uint256 index; index < calls.length; ++index) {
            targets[index] = _targetFor(label, index);
        }
        uint256[] memory values = new uint256[](calls.length);
        vm.prank(voters[0]);
        id = governor.propose(targets, values, calls, description);
        _add(string.concat(label, " propose"), _gas());
        vm.prank(investors[0]);
        assemblyGv.bindProposal(meetingId, itemIndex, id);
        _add(string.concat(label, " bind"), _gas());

        vm.warp(governor.proposalSnapshot(id) + 1);
        for (uint256 index; index < voters.length; ++index) {
            vm.prank(voters[index]);
            governor.castVote(id, 1);
            _add(string.concat(label, " vote"), _gas());
        }
        vm.warp(governor.proposalDeadline(id) + 1);
        bytes32 descriptionHash = keccak256(bytes(description));
        governor.queue(targets, values, calls, descriptionHash);
        _add(string.concat(label, " queue"), _gas());
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calls, descriptionHash);
        _add(string.concat(label, " execute"), _gas());
    }

    /// @dev Targets are recovered from the label so queue and execute rebuild the same calldata.
    function _targetFor(string memory label, uint256 index) internal view returns (address) {
        bytes32 key = keccak256(bytes(label));
        if (key == keccak256("agm terms")) return address(share);
        if (key == keccak256("agm report")) return address(info);
        if (key == keccak256("agm dividend")) return address(dividend);
        if (key == keccak256("egm observer")) return address(assemblyGv);
        revert(string.concat("unknown proposal ", label, " ", vm.toString(index)));
    }

    function _termsCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](3);
        calls[0] = abi.encodeCall(GvShare.setTransferPolicy, (address(terms)));
        calls[1] = abi.encodeCall(GvShare.setShareModule, (address(acquisition), true));
        calls[2] = abi.encodeCall(GvShare.setShareModule, (address(recovery), true));
    }

    function _reportCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(GvInformation.fulfillPublication, (dutyId, reportHash, CID));
    }

    function _dividendCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(
            GvDividend.startDistribution, (address(usdc), dividendRoot, dividendTotal, dividendDeadline, DIVIDEND_URI)
        );
    }

    function _egmCalls() internal view returns (bytes[] memory calls) {
        calls = new bytes[](1);
        calls[0] = abi.encodeCall(GvAssembly.setDirector, (observer, true));
    }

    function _voters(bool both) internal view returns (address[] memory voters) {
        voters = new address[](both ? 2 : 1);
        voters[0] = investors[0];
        if (both) voters[1] = investors[1];
    }

    function _roleAccounts() internal view returns (address[] memory roles) {
        roles = new address[](5);
        roles[0] = issuer;
        roles[1] = director;
        roles[2] = preBuyer;
        roles[3] = tagBuyer;
        roles[4] = dragBuyer;
    }

    function _mintApprove(address account, address spender, uint256 amount) internal {
        usdc.mint(account, amount);
        vm.startPrank(account);
        usdc.approve(spender, amount);
        uint256 used = _gas();
        vm.stopPrank();
        _add("approve consideration", used);
        assertEq(usdc.allowance(account, spender), amount, "consideration approval");
    }

    function _assertArticles(uint256 meetingId, uint256 item, uint256 proposalId) internal view {
        GvCompanyRules.ResolutionOutcome memory outcome = assemblyGv.articlesOutcome(meetingId, item, proposalId);
        assertEq(uint8(rules.bindingMode()), uint8(GvCompanyRules.BindingMode.Articles));
        assertTrue(outcome.passed, "articles passed");
        assertTrue(outcome.articlesQuorum, "articles quorum");
        assertTrue(outcome.articlesMajority, "articles majority");
        assertTrue(outcome.bravoMajority, "governor-shaped majority");
    }

    function _assertFinal() internal view {
        assertEq(share.totalSupply(), InvestorBook.SUPPLY);
        assertEq(share.balanceOf(address(acquisition)), 0);
        assertEq(share.balanceOf(address(terms)), 0);
        assertEq(share.balanceOf(issuer), 0);
        assertEq(share.balanceOf(hub), 0);
        assertEq(share.balanceOf(dragBuyer), 0);
        assertTrue(acquisition.drag(dragId).executed);
        assertFalse(acquisition.drag(dragId).surplusRefunded);
        assertTrue(acquisition.blocksPeerTransfers());
        assertEq(acquisition.drag(dragId).buyer, tagBuyer);
        assertEq(acquisition.drag(dragId).buyerHeldAtPost, 301_000);
        assertLt(acquisition.drag(dragId).paidOut, acquisition.drag(dragId).escrowed);

        assertEq(share.balanceOf(investors[0]), 0);
        assertEq(share.balanceOf(investors[1]), 0);
        assertEq(share.balanceOf(investors[2]), 0);
        assertEq(share.balanceOf(investors[3]), 0);
        assertEq(share.balanceOf(investors[4]), 0);
        assertEq(share.balanceOf(investors[6]), 0);
        assertEq(share.balanceOf(investors[7]), book[7]);
        assertEq(share.balanceOf(investors[10]), 0);
        assertEq(share.balanceOf(investors[holderCount - 1]), 0);
        assertEq(share.balanceOf(preBuyer), 0);
        assertEq(share.balanceOf(recovered), 0);
        assertGt(share.balanceOf(tagBuyer), 301_000);

        assertEq(acquisition.proceeds(investors[0], address(usdc)), book[0] * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(investors[1], address(usdc)), 181_000 * InvestorBook.PRICE);
        assertEq(terms.proceeds(investors[2], address(usdc)), 10_000 * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(investors[2], address(usdc)), 110_000 * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(investors[3], address(usdc)), 0);
        assertEq(usdc.balanceOf(investors[3]), 100_000 * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(investors[4], address(usdc)), book[4] * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(investors[6], address(usdc)), 0);
        assertEq(acquisition.proceeds(investors[7], address(usdc)), 0);
        assertEq(acquisition.proceeds(investors[10], address(usdc)), book[10] * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(recovered, address(usdc)), book[6] * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(preBuyer, address(usdc)), 9000 * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(tagBuyer, address(usdc)), 636_500 * InvestorBook.PRICE);
        assertEq(acquisition.proceeds(investors[holderCount - 1], address(usdc)), 0);
        assertEq(acquisition.proceeds(reserve, address(usdc)), book[holderCount - 1] * InvestorBook.PRICE);

        uint256 wallets = usdc.balanceOf(investors[0]) + usdc.balanceOf(investors[1]) + usdc.balanceOf(investors[3])
            + usdc.balanceOf(investors[holderCount / 2]) + usdc.balanceOf(investors[holderCount - 1]);
        uint256 located = wallets + usdc.balanceOf(address(dividend)) + usdc.balanceOf(address(terms))
            + usdc.balanceOf(address(acquisition));
        uint256 minted = dividendTotal + (1000 + 9000 + 937_500 + InvestorBook.SUPPLY) * InvestorBook.PRICE;
        assertEq(located, minted, "USDC conservation");
    }

    function _onboardingAccounts() internal view returns (address[] memory accounts) {
        address[] memory roles = _roleAccounts();
        accounts = new address[](holderCount + roles.length + 1);
        for (uint256 index; index < holderCount; ++index) {
            accounts[index] = investors[index];
        }
        for (uint256 index; index < roles.length; ++index) {
            accounts[holderCount + index] = roles[index];
        }
        accounts[holderCount + roles.length] = recovered;
    }

    function _whitelistBatches(address[] memory accounts)
        internal
        returns (uint256 first, uint256 last, uint256 sum, uint256 batches)
    {
        vm.startPrank(issuer);
        uint256 cursor;
        while (cursor < accounts.length) {
            uint256 n = accounts.length - cursor;
            if (n > terms.MAX_BATCH()) n = terms.MAX_BATCH();
            address[] memory slice = new address[](n);
            for (uint256 index; index < n; ++index) {
                slice[index] = accounts[cursor + index];
            }
            terms.setWhitelistBatch(slice, true);
            uint256 used = _gas();
            if (batches == 0) first = used;
            last = used;
            sum += used;
            batches += 1;
            cursor += n;
        }
        vm.stopPrank();
    }

    function _acceptBatches(address[] memory accounts, bytes32[][] memory tree)
        internal
        returns (uint256 first, uint256 last, uint256 sum, uint256 batches)
    {
        uint256 cursor;
        while (cursor < accounts.length) {
            uint256 n = accounts.length - cursor;
            if (n > terms.MAX_BATCH()) n = terms.MAX_BATCH();
            address[] memory slice = new address[](n);
            bytes32[][] memory proofs = new bytes32[][](n);
            for (uint256 index; index < n; ++index) {
                slice[index] = accounts[cursor + index];
                proofs[index] = MerkleBuilder.proof(tree, cursor + index);
            }
            terms.acceptShaWithProofBatch(slice, proofs);
            uint256 used = _gas();
            if (batches == 0) first = used;
            last = used;
            sum += used;
            batches += 1;
            cursor += n;
        }
    }

    function _assertIndependence() internal {
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), issuer));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), hub));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), hub));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), hub));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), hub));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), issuer));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(assemblyGv.isDirector(hub));
        assertFalse(share.shareModules(hub));
        assertEq(share.transferPolicy(), address(terms));
        assertEq(factory.deploymentByGovernor(address(governor)).issuer, issuer);

        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, hub));
        terms.setWhitelist(hub, true);
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(GvShare.OnlyTimelock.selector, hub));
        share.setTransferPolicy(address(0));
        vm.prank(hub);
        vm.expectRevert(abi.encodeWithSelector(GvDirectory.NotIssuerOrTimelock.selector, hub, issuer));
        directory.update(issuer, address(share), address(governor), address(timelock), address(dividend), "ipfs://nope");
    }

    function _begin(string memory name) internal {
        _flush();
        phaseName = name;
        phaseGas = 0;
    }

    function _flush() internal {
        if (bytes(phaseName).length == 0) return;
        console2.log(string.concat("SUBTOTAL ", phaseName), phaseGas);
        phaseName = "";
    }

    function _add(string memory step, uint256 gasUsed) internal {
        totalGas += gasUsed;
        phaseGas += gasUsed;
        console2.log(step, gasUsed);
    }

    function _gas() internal view returns (uint256) {
        return vm.lastFrameGas().gasTotalUsed;
    }
}
