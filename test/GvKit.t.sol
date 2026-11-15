// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { GvDirectory } from "../src/GvDirectory.sol";
import { GvDividend } from "../src/GvDividend.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvVotesWrapper } from "../src/GvVotesWrapper.sol";
import { GvCreate2Deployer, GvShareDeployer } from "../src/deployers/GvDeployers.sol";
import { KitFixture } from "./KitFixture.sol";
import { MerkleBuilder } from "./MerkleBuilder.sol";
import { BlockNumberVotes } from "./mocks/BlockNumberVotes.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract GvKitTest is KitFixture {
    address internal issuer = makeAddr("issuer");
    address internal holderB = makeAddr("holder-b");
    address internal holderC = makeAddr("holder-c");
    address internal stranger = makeAddr("stranger");

    function test_deploy_is_deterministic_and_factory_keeps_no_roles() public {
        GvKitFactory.ShareSpec memory shareSpec = _nativeSpec(100);
        GvKitFactory.GovSpec memory govSpec = _govSpec(1, 4);
        bytes32 salt = bytes32(uint256(1));

        (address pShare, address pGov, address pTl, address pDiv) = factory.predict(issuer, shareSpec, govSpec, salt);
        (address share, GvGovernor governor, TimelockController timelock, GvDividend dividend) =
            _deploy(issuer, shareSpec, govSpec, salt);

        assertEq(share, pShare);
        assertEq(address(governor), pGov);
        assertEq(address(timelock), pTl);
        assertEq(address(dividend), pDiv);

        assertEq(GvShare(share).timelock(), address(timelock));
        assertEq(dividend.timelock(), address(timelock));
        assertEq(governor.timelock(), address(timelock));
        assertEq(address(governor.token()), share);
        assertEq(GvShare(share).balanceOf(issuer), 100);
        assertEq(GvShare(share).decimals(), 0);
        assertEq(GvShare(share).CLOCK_MODE(), "mode=timestamp");
        assertEq(governor.CLOCK_MODE(), "mode=timestamp");
        assertEq(governor.COUNTING_MODE(), "support=bravo&quorum=for,abstain");
        assertEq(governor.votingDelay(), 1);
        assertEq(governor.quorumNumerator(), 4);

        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), address(governor)));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(timelock)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), issuer));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(factory)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), issuer));

        bytes32 proposerRole = timelock.PROPOSER_ROLE();
        vm.prank(address(factory));
        vm.expectRevert();
        timelock.grantRole(proposerRole, stranger);

        GvKitFactory.Deployment memory stored = factory.deploymentByGovernor(address(governor));
        assertEq(stored.issuer, issuer);
        assertEq(stored.share, share);
        assertEq(uint8(stored.kind), uint8(GvKitFactory.VotesKind.NativeShare));
        assertEq(directory.get(issuer).governor, address(0));
    }

    function test_same_salt_cannot_be_reused_by_the_same_issuer() public {
        GvKitFactory.ShareSpec memory shareSpec = _nativeSpec(10);
        GvKitFactory.GovSpec memory govSpec = _govSpec(1, 4);
        _deploy(issuer, shareSpec, govSpec, bytes32(uint256(7)));
        vm.prank(issuer);
        vm.expectRevert(GvCreate2Deployer.Create2Failed.selector);
        factory.deploy(shareSpec, govSpec, "ipfs://gv-kit-test", bytes32(uint256(7)));
    }

    function test_two_issuers_may_reuse_a_salt() public {
        GvKitFactory.ShareSpec memory shareSpec = _nativeSpec(10);
        GvKitFactory.GovSpec memory govSpec = _govSpec(1, 4);
        (address a,,,) = _deploy(issuer, shareSpec, govSpec, bytes32(uint256(7)));
        (address b,,,) = _deploy(holderB, shareSpec, govSpec, bytes32(uint256(7)));
        assertTrue(a != b);
    }

    function test_native_share_mint_only_through_governance() public {
        (address share, GvGovernor governor,,) = _deploy(issuer, _nativeSpec(100), _govSpec(1, 4), bytes32(uint256(2)));
        _delegate(share, issuer);

        vm.prank(issuer);
        vm.expectPartialRevert(GvShare.OnlyTimelock.selector);
        GvShare(share).mint(holderB, 5);

        address[] memory targets = new address[](1);
        targets[0] = share;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GvShare.mint, (holderB, 5));
        _pass(governor, issuer, targets, calldatas, "Capital increase of 5 shares");

        assertEq(GvShare(share).balanceOf(holderB), 5);
        assertEq(GvShare(share).totalSupply(), 105);
    }

    function test_direct_parameter_change_reverts_and_proposal_can_change_it() public {
        (address share, GvGovernor governor,,) = _deploy(issuer, _nativeSpec(100), _govSpec(1, 4), bytes32(uint256(3)));
        _delegate(share, issuer);

        vm.expectRevert();
        governor.setVotingDelay(9);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GovernorSettings.setVotingDelay, (uint48(9)));
        _pass(governor, issuer, targets, calldatas, "Set voting delay to 9 seconds");
        assertEq(governor.votingDelay(), 9);
    }

    function test_counting_quorum_and_snapshot() public {
        (address share, GvGovernor governor,,) = _deploy(issuer, _nativeSpec(100), _govSpec(1, 50), bytes32(uint256(4)));
        GvShare token = GvShare(share);
        vm.prank(issuer);
        token.transfer(holderB, 30);
        vm.prank(issuer);
        token.transfer(holderC, 20);
        _delegate(share, issuer);
        _delegate(share, holderB);
        _delegate(share, holderC);
        vm.warp(vm.getBlockTimestamp() + 1);

        address[] memory targets = new address[](1);
        targets[0] = address(governor);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GovernorSettings.setVotingDelay, (uint48(2)));
        string memory description = "Resolution A";
        vm.prank(issuer);
        uint256 id = governor.propose(targets, values, calldatas, description);

        vm.warp(governor.proposalSnapshot(id) + 1);
        uint256 leftover = token.balanceOf(issuer);
        vm.prank(issuer);
        token.transfer(stranger, leftover);

        vm.prank(issuer);
        governor.castVote(id, 1);
        vm.prank(holderB);
        governor.castVote(id, 0);
        vm.prank(holderC);
        governor.castVote(id, 2);

        (uint256 againstVotes, uint256 forVotes, uint256 abstainVotes) = governor.proposalVotes(id);
        assertEq(againstVotes, 30);
        assertEq(forVotes, 50);
        assertEq(abstainVotes, 20);
        assertEq(governor.quorum(governor.proposalSnapshot(id)), 50);

        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Succeeded));
    }

    function test_defeat_when_against_leads() public {
        (address share, GvGovernor governor,,) = _deploy(issuer, _nativeSpec(100), _govSpec(1, 20), bytes32(uint256(5)));
        GvShare token = GvShare(share);
        vm.prank(issuer);
        token.transfer(holderB, 60);
        _delegate(share, issuer);
        _delegate(share, holderB);
        vm.warp(vm.getBlockTimestamp() + 1);

        address[] memory targets = new address[](1);
        targets[0] = share;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GvShare.mint, (issuer, 1));
        vm.prank(issuer);
        uint256 id = governor.propose(targets, values, calldatas, "Resolution B");
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(issuer);
        governor.castVote(id, 1);
        vm.prank(holderB);
        governor.castVote(id, 0);
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_quorum_not_met() public {
        (address share, GvGovernor governor,,) =
            _deploy(issuer, _nativeSpec(100), _govSpec(25, 51), bytes32(uint256(6)));
        GvShare token = GvShare(share);
        vm.prank(issuer);
        token.transfer(holderC, 20);
        _delegate(share, issuer);
        _delegate(share, holderC);
        vm.warp(vm.getBlockTimestamp() + 1);

        address[] memory targets = new address[](1);
        targets[0] = share;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GvShare.mint, (issuer, 1));
        vm.prank(holderC);
        vm.expectRevert();
        governor.propose(targets, values, calldatas, "Too small to propose");

        vm.prank(issuer);
        uint256 id = governor.propose(targets, values, calldatas, "Resolution C");
        vm.warp(governor.proposalSnapshot(id) + 1);
        vm.prank(holderC);
        governor.castVote(id, 1);
        vm.warp(governor.proposalDeadline(id) + 1);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Defeated));
    }

    function test_proposer_can_cancel_only_while_pending() public {
        (address share, GvGovernor governor,,) = _deploy(issuer, _nativeSpec(100), _govSpec(1, 4), bytes32(uint256(8)));
        _delegate(share, issuer);
        address[] memory targets = new address[](1);
        targets[0] = share;
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GvShare.mint, (issuer, 1));
        string memory description = "Cancel me";
        vm.prank(issuer);
        uint256 id = governor.propose(targets, values, calldatas, description);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Pending));
        vm.prank(stranger);
        vm.expectRevert();
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
        vm.prank(issuer);
        governor.cancel(targets, values, calldatas, keccak256(bytes(description)));
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Canceled));
    }

    function test_permit_and_timestamp_clock() public {
        (address share,,,) = _deploy(issuer, _nativeSpec(10), _govSpec(1, 4), bytes32(uint256(9)));
        GvShare token = GvShare(share);
        uint256 pk = uint256(keccak256("gv-kit-test-only-permit-key"));
        address owner = vm.addr(pk);
        vm.prank(issuer);
        token.transfer(owner, 2);

        uint256 deadline = block.timestamp + 1 days;
        bytes32 typehash =
            keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
        bytes32 structHash = keccak256(abi.encode(typehash, owner, holderB, 2, token.nonces(owner), deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", token.DOMAIN_SEPARATOR(), structHash));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(pk, digest);
        token.permit(owner, holderB, 2, deadline, v, r, s);
        vm.prank(holderB);
        token.transferFrom(owner, holderC, 2);
        assertEq(token.balanceOf(holderC), 2);
        assertEq(token.clock(), uint48(block.timestamp));
    }

    function test_dividend_flow_and_access() public {
        (address share, GvGovernor governor, TimelockController timelock, GvDividend dividend) =
            _deploy(issuer, _nativeSpec(100), _govSpec(1, 4), bytes32(uint256(10)));
        _delegate(share, issuer);

        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        uint256 amount = 1_000_000;
        bytes32 leaf = dividend.hashLeaf(0, holderB, amount);
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = leaf;
        bytes32 root = MerkleBuilder.root(MerkleBuilder.build(leaves));

        uint64 deadline = uint64(vm.getBlockTimestamp() + 7 days);
        vm.prank(issuer);
        vm.expectPartialRevert(GvDividend.OnlyTimelock.selector);
        dividend.startDistribution(address(usdc), root, amount, deadline, "ipfs://tree");

        address[] memory targets = new address[](1);
        targets[0] = address(dividend);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeCall(GvDividend.startDistribution, (address(usdc), root, amount, deadline, "ipfs://tree"));
        _pass(governor, issuer, targets, calldatas, "Dividend 1");

        (,, uint256 total, uint256 funded,,,,) = dividend.distribution(0);
        assertEq(total, amount);
        assertEq(funded, 0);
        bytes32[] memory proof = new bytes32[](0);
        vm.expectPartialRevert(GvDividend.NotFullyFunded.selector);
        dividend.claim(0, 0, holderB, amount, proof);

        usdc.mint(issuer, amount);
        vm.prank(issuer);
        usdc.approve(address(dividend), amount);
        vm.prank(issuer);
        dividend.fund(0, amount);

        vm.expectPartialRevert(GvDividend.InvalidProof.selector);
        dividend.claim(0, 0, holderC, amount, proof);

        dividend.claim(0, 0, holderB, amount, proof);
        assertEq(usdc.balanceOf(holderB), amount);
        vm.expectPartialRevert(GvDividend.AlreadyClaimed.selector);
        dividend.claim(0, 0, holderB, amount, proof);

        vm.warp(vm.getBlockTimestamp() + 8 days);
        vm.prank(stranger);
        vm.expectPartialRevert(GvDividend.OnlyTimelock.selector);
        dividend.sweep(0, stranger);
        vm.prank(address(timelock));
        vm.expectPartialRevert(GvDividend.NothingToSweep.selector);
        dividend.sweep(0, issuer);

        bytes32 executorRole = timelock.EXECUTOR_ROLE();
        assertFalse(timelock.hasRole(executorRole, stranger));
        uint256[] memory noValues = new uint256[](1);
        vm.prank(stranger);
        vm.expectRevert();
        timelock.executeBatch(targets, noValues, calldatas, bytes32(0), bytes32(0));
    }

    function test_sweep_unclaimed_after_deadline() public {
        (, GvGovernor governor, TimelockController timelock, GvDividend dividend) =
            _deploy(issuer, _nativeSpec(100), _govSpec(1, 4), bytes32(uint256(11)));
        _delegate(address(governor.token()), issuer);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        uint256 amount = 2_000_000;
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = dividend.hashLeaf(0, holderB, amount);
        bytes32 root = MerkleBuilder.root(MerkleBuilder.build(leaves));
        uint64 deadline = uint64(vm.getBlockTimestamp() + 1 days);

        address[] memory targets = new address[](1);
        targets[0] = address(dividend);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeCall(GvDividend.startDistribution, (address(usdc), root, amount, deadline, "ipfs://tree"));
        _pass(governor, issuer, targets, calldatas, "Dividend to sweep");

        usdc.mint(stranger, amount);
        vm.startPrank(stranger);
        usdc.approve(address(dividend), amount);
        dividend.fund(0, amount);
        vm.stopPrank();

        vm.prank(address(timelock));
        vm.expectPartialRevert(GvDividend.DeadlineNotReached.selector);
        dividend.sweep(0, issuer);

        vm.warp(deadline + 1);
        vm.prank(address(timelock));
        uint256 swept = dividend.sweep(0, issuer);
        assertEq(swept, amount);
        assertEq(usdc.balanceOf(issuer), amount);
        vm.prank(address(timelock));
        vm.expectPartialRevert(GvDividend.AlreadySwept.selector);
        dividend.sweep(0, issuer);
    }

    function test_wrapper_around_plain_erc20() public {
        MockERC20 underlying = new MockERC20("CMTAT-like", "CMT", 0);
        underlying.mint(holderB, 25);
        GvKitFactory.ShareSpec memory shareSpec = GvKitFactory.ShareSpec({
            name: "Wrapped CMTAT-like",
            symbol: "wCMT",
            decimals: 0,
            initialSupply: 0,
            existingUnderlying: address(underlying),
            existingVotesToken: address(0)
        });
        (address share, GvGovernor governor,,) = _deploy(issuer, shareSpec, _govSpec(1, 4), bytes32(uint256(12)));
        GvVotesWrapper wrapper = GvVotesWrapper(share);
        assertEq(address(wrapper.underlying()), address(underlying));
        assertEq(wrapper.decimals(), 0);
        assertEq(wrapper.CLOCK_MODE(), "mode=timestamp");
        assertEq(address(governor.token()), share);
        assertEq(
            uint8(factory.deploymentByGovernor(address(governor)).kind), uint8(GvKitFactory.VotesKind.WrappedUnderlying)
        );

        vm.startPrank(holderB);
        underlying.approve(share, 25);
        wrapper.depositFor(holderB, 25);
        wrapper.delegate(holderB);
        vm.stopPrank();
        assertEq(wrapper.getVotes(holderB), 25);
        assertEq(underlying.balanceOf(share), 25);

        vm.prank(holderB);
        wrapper.withdrawTo(holderB, 10);
        assertEq(underlying.balanceOf(holderB), 10);
        assertEq(wrapper.balanceOf(holderB), 15);
    }

    function test_existing_timestamp_votes_token_and_reject_block_clock() public {
        (address share,,,) = _deploy(issuer, _nativeSpec(40), _govSpec(1, 4), bytes32(uint256(13)));
        GvKitFactory.ShareSpec memory reuse = GvKitFactory.ShareSpec({
            name: "",
            symbol: "",
            decimals: 0,
            initialSupply: 0,
            existingUnderlying: address(0),
            existingVotesToken: share
        });
        (, GvGovernor governor,,) = _deploy(holderB, reuse, _govSpec(1, 4), bytes32(uint256(14)));
        assertEq(address(governor.token()), share);
        assertEq(
            uint8(factory.deploymentByGovernor(address(governor)).kind), uint8(GvKitFactory.VotesKind.ExistingVotes)
        );

        BlockNumberVotes blockVotes = new BlockNumberVotes();
        GvKitFactory.ShareSpec memory bad = reuse;
        bad.existingVotesToken = address(blockVotes);
        vm.prank(issuer);
        vm.expectRevert(abi.encodeWithSelector(GvKitFactory.ClockNotTimestamp.selector, address(blockVotes)));
        factory.deploy(bad, _govSpec(1, 4), "ipfs://gv-kit-test", bytes32(uint256(15)));
    }

    function test_directory_is_optional_and_ownerless() public {
        (address share, GvGovernor governor, TimelockController timelock, GvDividend dividend) =
            _deploy(issuer, _nativeSpec(10), _govSpec(1, 4), bytes32(uint256(16)));
        _delegate(share, issuer);
        address[] memory targets = new address[](1);
        targets[0] = share;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GvShare.mint, (issuer, 1));
        _pass(governor, issuer, targets, calldatas, "Meeting without a directory");
        assertEq(GvShare(share).totalSupply(), 11);
        assertEq(directory.get(issuer).governor, address(0));

        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GvDirectory.NotRegistered.selector, issuer));
        directory.update(issuer, share, address(governor), address(timelock), address(dividend), "ipfs://x");

        vm.prank(issuer);
        directory.register(share, address(governor), address(timelock), address(dividend), "ipfs://kit");
        assertEq(directory.get(issuer).governor, address(governor));

        vm.prank(stranger);
        vm.expectRevert();
        directory.update(issuer, share, address(governor), address(timelock), address(dividend), "ipfs://no");

        vm.prank(address(timelock));
        directory.update(issuer, share, address(governor), address(timelock), address(dividend), "ipfs://via-timelock");
        assertEq(directory.get(issuer).metadataURI, "ipfs://via-timelock");

        vm.prank(issuer);
        vm.expectRevert();
        directory.register(share, address(governor), address(timelock), address(dividend), "ipfs://again");

        (bool ok,) = address(directory).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = address(factory).call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
        (ok,) = share.call(abi.encodeWithSignature("owner()"));
        assertFalse(ok);
    }

    /// @dev Root produced by script/build_merkle.py for indexes 0..2, accounts 0x1/0x2/0x3, amounts 5/7/9.
    function test_merkle_matches_offchain_builder() public {
        GvDividend dividend = new GvDividend(issuer);
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = dividend.hashLeaf(0, address(0x1), 5);
        leaves[1] = dividend.hashLeaf(1, address(0x2), 7);
        leaves[2] = dividend.hashLeaf(2, address(0x3), 9);
        bytes32[][] memory levels = MerkleBuilder.build(leaves);
        assertEq(
            MerkleBuilder.root(levels), bytes32(0x35413f47f3f82aed582c280bd658d934800923c6c02d63a18365ac7757e524be)
        );
        bytes32[] memory proof = MerkleBuilder.proof(levels, 2);
        assertEq(proof.length, 1);
        assertEq(proof[0], bytes32(0x85ff50a42bc6b228fd2aeff9eeb3db8ddfb183ab9b43895e93a93f4c02f7fc1a));
    }

    function test_merkle_three_leaves_roundtrip() public {
        GvDividend dividend = new GvDividend(issuer);
        bytes32[] memory leaves = new bytes32[](3);
        leaves[0] = dividend.hashLeaf(0, holderB, 5);
        leaves[1] = dividend.hashLeaf(1, holderC, 7);
        leaves[2] = dividend.hashLeaf(2, stranger, 9);
        bytes32[][] memory levels = MerkleBuilder.build(leaves);
        bytes32 root = MerkleBuilder.root(levels);
        for (uint256 i; i < 3; ++i) {
            bytes32[] memory proof = MerkleBuilder.proof(levels, i);
            assertTrue(_verify(proof, root, leaves[i]));
        }
        bytes32[] memory bad = MerkleBuilder.proof(levels, 0);
        assertFalse(_verify(bad, root, dividend.hashLeaf(0, holderB, 6)));
    }

    function test_deployer_rejects_stranger() public {
        GvShareDeployer.ShareInit memory cfg = GvShareDeployer.ShareInit({
            name: "Example Shares", symbol: "EXS", decimals: 0, issuer: issuer, initialSupply: 1, timelock: issuer
        });
        GvShareDeployer deployer = factory.shareDeployer();
        vm.expectRevert(abi.encodeWithSelector(GvCreate2Deployer.OnlyFactory.selector, address(this)));
        deployer.deploy(bytes32(uint256(1)), cfg);
    }

    function _verify(bytes32[] memory proof, bytes32 root, bytes32 leaf) private pure returns (bool) {
        bytes32 computed = leaf;
        for (uint256 i; i < proof.length; ++i) {
            bytes32 a = computed;
            bytes32 b = proof[i];
            computed = a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
        }
        return computed == root;
    }
}
