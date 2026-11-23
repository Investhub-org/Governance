// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { GvAcquisition } from "../src/GvAcquisition.sol";
import { GvAssembly } from "../src/GvAssembly.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvDividend } from "../src/GvDividend.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvInformation } from "../src/GvInformation.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import { GvRecovery } from "../src/GvRecovery.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvShareTerms } from "../src/GvShareTerms.sol";
import { KitFixture } from "./KitFixture.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

contract GvIssuerSetTest is KitFixture {
    address internal issuer = makeAddr("issuer");
    address internal other = makeAddr("other-issuer");
    address internal hub = makeAddr("investhub");
    MockERC20 internal consideration;

    function setUp() public override {
        super.setUp();
        consideration = new MockERC20("Example USD", "USDX", 6);
    }

    function test_deploySet_is_deterministic_and_issuer_owned() public {
        GvKitFactory.ShareSpec memory shareSpec = _nativeSpec(1000);
        GvKitFactory.GovSpec memory govSpec = _govSpec(1, 4);
        bytes32 salt = bytes32(uint256(11));

        (address predictedShare, address predictedGov, address predictedTl, address predictedDiv) =
            factory.predict(issuer, shareSpec, govSpec, salt);
        GvKitFactory.PredictedSet memory predicted =
            factory.predictSet(issuer, shareSpec, govSpec, address(consideration), salt);
        assertEq(predicted.share, predictedShare);
        assertEq(predicted.governor, predictedGov);
        assertEq(predicted.timelock, predictedTl);
        assertEq(predicted.dividend, predictedDiv);

        vm.prank(issuer);
        GvKitFactory.PredictedSet memory deployed =
            factory.deploySet(shareSpec, govSpec, "ipfs://gv-issuer-set", address(consideration), salt);
        uint256 gasUsed = vm.lastFrameGas().gasTotalUsed;
        assertEq(deployed.share, predicted.share);
        assertEq(deployed.governor, predicted.governor);
        assertEq(deployed.timelock, predicted.timelock);
        assertEq(deployed.dividend, predicted.dividend);
        assertEq(deployed.rules, predicted.rules);
        assertEq(deployed.assembly_, predicted.assembly_);
        assertEq(deployed.information, predicted.information);
        assertEq(deployed.terms, predicted.terms);
        assertEq(deployed.acquisition, predicted.acquisition);
        assertEq(deployed.recovery, predicted.recovery);
        assertLt(gasUsed, 25_000_000, "deploySet must fit a 25 million gas block");

        _assertOwnedByIssuer(issuer, deployed);
        _assertNoHubOrFactoryAdmin(deployed);

        GvKitFactory.Deployment memory stored = factory.deploymentByGovernor(deployed.governor);
        assertEq(stored.issuer, issuer);
        assertEq(stored.rules, deployed.rules);
        assertEq(stored.recovery, deployed.recovery);
        assertEq(uint8(stored.kind), uint8(GvKitFactory.VotesKind.NativeShare));

        _delegate(deployed.share, issuer);
        address[] memory targets = new address[](1);
        targets[0] = deployed.share;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GvShare.mint, (other, 5));
        _pass(GvGovernor(payable(deployed.governor)), issuer, targets, calldatas, "Mint five shares");
        assertEq(GvShare(deployed.share).balanceOf(other), 5);
    }

    function test_kit_only_deploy_leaves_modules_unset_and_drops_wirer() public {
        (address share, GvGovernor governor,,) = _deploy(issuer, _nativeSpec(100), _govSpec(1, 4), bytes32(uint256(3)));
        assertEq(governor.articlesIssuer(), issuer);
        assertEq(governor.articlesWirer(), address(0));
        assertEq(governor.articlesGate(), address(0));
        GvKitFactory.Deployment memory stored = factory.deploymentByGovernor(address(governor));
        assertEq(stored.rules, address(0));
        assertEq(stored.terms, address(0));
        assertEq(GvShare(share).transferPolicy(), address(0));

        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(GvGovernor.NotArticlesIssuer.selector, address(factory)));
        governor.setArticlesGate(share);

        vm.prank(issuer);
        governor.setArticlesGate(share);
        assertEq(governor.articlesGate(), share);
    }

    function test_same_salt_cannot_deploy_the_set_twice() public {
        GvKitFactory.ShareSpec memory shareSpec = _nativeSpec(10);
        GvKitFactory.GovSpec memory govSpec = _govSpec(1, 4);
        bytes32 salt = bytes32(uint256(9));
        vm.prank(issuer);
        factory.deploySet(shareSpec, govSpec, "ipfs://gv-issuer-set", address(consideration), salt);
        vm.prank(issuer);
        vm.expectRevert();
        factory.deploySet(shareSpec, govSpec, "ipfs://gv-issuer-set", address(consideration), salt);
    }

    function test_two_issuers_may_reuse_a_salt_for_the_set() public {
        GvKitFactory.ShareSpec memory shareSpec = _nativeSpec(10);
        GvKitFactory.GovSpec memory govSpec = _govSpec(1, 4);
        bytes32 salt = bytes32(uint256(9));
        vm.prank(issuer);
        GvKitFactory.PredictedSet memory a =
            factory.deploySet(shareSpec, govSpec, "ipfs://gv-issuer-set", address(consideration), salt);
        vm.prank(other);
        GvKitFactory.PredictedSet memory b =
            factory.deploySet(shareSpec, govSpec, "ipfs://gv-issuer-set", address(consideration), salt);
        assertTrue(a.share != b.share);
        assertTrue(a.governor != b.governor);
        assertTrue(a.rules != b.rules);
        assertEq(GvCompanyRules(b.rules).owner(), other);
    }

    function test_modules_require_a_native_share_and_a_token_contract() public {
        GvKitFactory.GovSpec memory govSpec = _govSpec(1, 4);
        GvKitFactory.ShareSpec memory wrapped = _nativeSpec(0);
        wrapped.existingUnderlying = address(consideration);
        vm.expectRevert(GvKitFactory.ModulesNeedNativeShare.selector);
        factory.predictSet(issuer, wrapped, govSpec, address(consideration), bytes32(uint256(1)));

        GvKitFactory.ShareSpec memory votes = _nativeSpec(0);
        votes.initialSupply = 0;
        votes.existingVotesToken = address(consideration);
        vm.expectRevert(GvKitFactory.ModulesNeedNativeShare.selector);
        factory.predictSet(issuer, votes, govSpec, address(consideration), bytes32(uint256(1)));

        vm.expectRevert(GvKitFactory.ConsiderationUnset.selector);
        factory.predictSet(issuer, _nativeSpec(10), govSpec, other, bytes32(uint256(1)));
    }

    struct FuzzInput {
        uint256 supply;
        uint8 decimals;
        uint256 quorum;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 threshold;
        bytes32 salt;
        address issuer;
    }

    function testFuzz_deploySet_matches_predict_and_keeps_no_admin(
        uint96 rawSupply,
        uint8 rawDecimals,
        uint8 rawQuorum,
        uint32 rawDelay,
        uint32 rawPeriod,
        uint256 rawThreshold,
        bytes32 salt,
        address rawIssuer
    ) public {
        FuzzInput memory input;
        input.supply = bound(rawSupply, 1, 1_000_000_000);
        input.decimals = uint8(bound(uint256(rawDecimals), 0, 18));
        input.quorum = bound(uint256(rawQuorum), 1, 100);
        input.votingDelay = uint48(bound(uint256(rawDelay), 1, 30 days));
        input.votingPeriod = uint32(bound(uint256(rawPeriod), 1, 30 days));
        input.threshold = bound(rawThreshold, 0, input.supply);
        input.salt = salt;
        input.issuer = address(uint160(bound(uint256(uint160(rawIssuer)), 0x100, type(uint160).max)));
        _fuzz(input);
    }

    function _fuzz(FuzzInput memory input) internal {
        vm.assume(input.issuer.code.length == 0);
        vm.assume(input.issuer != address(factory));
        vm.assume(input.issuer != address(consideration));
        vm.assume(input.issuer != hub);
        GvKitFactory.ShareSpec memory shareSpec = GvKitFactory.ShareSpec({
            name: "Fuzz Shares",
            symbol: "FZS",
            decimals: input.decimals,
            initialSupply: input.supply,
            existingUnderlying: address(0),
            existingVotesToken: address(0)
        });
        GvKitFactory.GovSpec memory govSpec = GvKitFactory.GovSpec({
            name: "Fuzz Governor",
            votingDelay: input.votingDelay,
            votingPeriod: input.votingPeriod,
            proposalThreshold: input.threshold,
            quorumNumerator: input.quorum,
            timelockDelay: 1
        });
        _fuzzDeploy(input, shareSpec, govSpec);
    }

    function _fuzzDeploy(
        FuzzInput memory input,
        GvKitFactory.ShareSpec memory shareSpec,
        GvKitFactory.GovSpec memory govSpec
    ) internal {
        GvKitFactory.PredictedSet memory predicted = factory.predictSet(
            input.issuer, shareSpec, govSpec, address(consideration), input.salt
        );
        vm.prank(input.issuer);
        GvKitFactory.PredictedSet memory deployed =
            factory.deploySet(shareSpec, govSpec, "ipfs://gv-fuzz", address(consideration), input.salt);
        _assertPredicted(predicted, deployed);
        assertEq(GvShare(deployed.share).balanceOf(input.issuer), input.supply);
        assertEq(GvShare(deployed.share).decimals(), input.decimals);
        _assertOwnedByIssuer(input.issuer, deployed);
        _assertNoHubOrFactoryAdmin(deployed);
    }

    function _assertPredicted(GvKitFactory.PredictedSet memory predicted, GvKitFactory.PredictedSet memory deployed)
        internal
        pure
    {
        assertEq(deployed.share, predicted.share);
        assertEq(deployed.governor, predicted.governor);
        assertEq(deployed.timelock, predicted.timelock);
        assertEq(deployed.dividend, predicted.dividend);
        assertEq(deployed.rules, predicted.rules);
        assertEq(deployed.assembly_, predicted.assembly_);
        assertEq(deployed.information, predicted.information);
        assertEq(deployed.terms, predicted.terms);
        assertEq(deployed.acquisition, predicted.acquisition);
        assertEq(deployed.recovery, predicted.recovery);
    }

    function _assertOwnedByIssuer(address issuer_, GvKitFactory.PredictedSet memory set) internal {
        GvShare share = GvShare(set.share);
        GvGovernor governor = GvGovernor(payable(set.governor));
        GvCompanyRules rules = GvCompanyRules(set.rules);
        GvAssembly assemblyGv = GvAssembly(set.assembly_);
        GvInformation info = GvInformation(set.information);
        GvShareTerms terms = GvShareTerms(set.terms);
        GvAcquisition acquisition = GvAcquisition(set.acquisition);
        GvRecovery recovery = GvRecovery(set.recovery);

        assertEq(share.balanceOf(issuer_), share.totalSupply());
        assertEq(share.timelock(), set.timelock);
        assertEq(share.transferPolicy(), address(0));
        assertFalse(share.shareModules(set.terms));
        assertFalse(share.shareModules(set.acquisition));
        assertFalse(share.shareModules(set.recovery));
        assertFalse(share.shareModules(address(factory)));
        assertFalse(share.shareModules(hub));

        assertEq(governor.articlesIssuer(), issuer_);
        assertEq(governor.articlesGate(), set.assembly_);
        assertEq(governor.articlesWirer(), address(0));
        assertEq(governor.timelock(), set.timelock);
        assertEq(address(governor.token()), set.share);

        assertEq(rules.owner(), issuer_);
        assertEq(assemblyGv.owner(), issuer_);
        assertEq(address(assemblyGv.token()), set.share);
        assertEq(address(assemblyGv.rules()), set.rules);
        assertEq(address(assemblyGv.governor()), set.governor);
        assertEq(address(info.token()), set.share);
        assertEq(address(info.rules()), set.rules);
        assertEq(address(info.assembly_()), set.assembly_);

        assertEq(terms.owner(), issuer_);
        assertEq(terms.acquisitionBinder(), address(0));
        assertEq(terms.acquisition(), set.acquisition);
        assertEq(terms.consideration(), address(consideration));
        assertEq(address(terms.token()), set.share);
        assertEq(address(acquisition.terms()), set.terms);
        assertEq(address(acquisition.token()), set.share);
        assertEq(recovery.timelock(), set.timelock);
        assertEq(address(recovery.token()), set.share);
        assertEq(address(recovery.assembly_()), set.assembly_);
        assertEq(GvDividend(set.dividend).timelock(), set.timelock);

        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, address(factory)));
        terms.setAcquisition(hub);

        vm.prank(address(factory));
        vm.expectRevert(abi.encodeWithSelector(GvGovernor.NotArticlesTimelock.selector, address(factory)));
        governor.setArticlesGate(hub);
    }

    function _assertNoHubOrFactoryAdmin(GvKitFactory.PredictedSet memory set) internal view {
        TimelockController timelock = TimelockController(payable(set.timelock));
        assertTrue(timelock.hasRole(timelock.PROPOSER_ROLE(), set.governor));
        assertTrue(timelock.hasRole(timelock.EXECUTOR_ROLE(), set.governor));
        assertTrue(timelock.hasRole(timelock.CANCELLER_ROLE(), set.governor));
        assertTrue(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), set.timelock));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), address(factory)));
        assertFalse(timelock.hasRole(timelock.DEFAULT_ADMIN_ROLE(), hub));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), address(factory)));
        assertFalse(timelock.hasRole(timelock.PROPOSER_ROLE(), hub));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), hub));
        assertFalse(timelock.hasRole(timelock.EXECUTOR_ROLE(), address(0)));
        assertFalse(timelock.hasRole(timelock.CANCELLER_ROLE(), hub));
    }
}
