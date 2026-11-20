// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GvAssembly } from "../src/GvAssembly.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvDirectory } from "../src/GvDirectory.sol";
import { GvDividend } from "../src/GvDividend.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import { GvShare } from "../src/GvShare.sol";
import {
    GvDividendDeployer,
    GvGovernorDeployer,
    GvShareDeployer,
    GvTimelockDeployer,
    GvVotesWrapperDeployer
} from "../src/deployers/GvDeployers.sol";

abstract contract KitFixture is Test {
    GvKitFactory internal factory;
    GvDirectory internal directory;

    function setUp() public virtual {
        factory = _deployFactory();
        directory = new GvDirectory();
    }

    /// @dev Five deployer transactions, then the factory. One initcode would exceed EIP-3860.
    function _deployFactory() internal returns (GvKitFactory deployed) {
        uint256 nonce = vm.getNonce(address(this));
        address predicted = vm.computeCreateAddress(address(this), nonce + 5);
        GvShareDeployer shareD = new GvShareDeployer(predicted);
        GvVotesWrapperDeployer wrapD = new GvVotesWrapperDeployer(predicted);
        GvTimelockDeployer timeD = new GvTimelockDeployer(predicted);
        GvGovernorDeployer govD = new GvGovernorDeployer(predicted);
        GvDividendDeployer divD = new GvDividendDeployer(predicted);
        deployed = new GvKitFactory(shareD, wrapD, timeD, govD, divD);
        assertEq(address(deployed), predicted);
    }

    function _nativeSpec(uint256 supply) internal pure returns (GvKitFactory.ShareSpec memory) {
        return GvKitFactory.ShareSpec({
            name: "Example Shares",
            symbol: "EXS",
            decimals: 0,
            initialSupply: supply,
            existingUnderlying: address(0),
            existingVotesToken: address(0)
        });
    }

    function _govSpec(uint256 threshold, uint256 quorum) internal pure returns (GvKitFactory.GovSpec memory) {
        return GvKitFactory.GovSpec({
            name: "Example Governor",
            votingDelay: 1,
            votingPeriod: 3600,
            proposalThreshold: threshold,
            quorumNumerator: quorum,
            timelockDelay: 1
        });
    }

    function _deploy(
        address issuer,
        GvKitFactory.ShareSpec memory shareSpec,
        GvKitFactory.GovSpec memory govSpec,
        bytes32 salt
    ) internal returns (address share, GvGovernor governor, TimelockController timelock, GvDividend dividend) {
        vm.prank(issuer);
        (address shareAddr, address governorAddr, address timelockAddr, address dividendAddr) =
            factory.deploy(shareSpec, govSpec, "ipfs://gv-kit-test", salt);
        share = shareAddr;
        governor = GvGovernor(payable(governorAddr));
        timelock = TimelockController(payable(timelockAddr));
        dividend = GvDividend(dividendAddr);
    }

    /// @dev Delegates, then moves one second forward. Governor reads proposer votes at `clock() - 1`,
    /// so a checkpoint written in the current second is not visible until the next second.
    function _delegate(address votesToken, address account) internal {
        vm.prank(account);
        IVotes(votesToken).delegate(account);
        vm.warp(vm.getBlockTimestamp() + 1);
    }

    function _pass(
        GvGovernor governor,
        address voter,
        address[] memory targets,
        bytes[] memory calldatas,
        string memory description
    ) internal returns (uint256 proposalId) {
        _ensureArticlesGate(governor);
        uint256[] memory values = new uint256[](targets.length);
        vm.prank(voter);
        proposalId = governor.propose(targets, values, calldatas, description);
        vm.warp(governor.proposalSnapshot(proposalId) + 1);
        vm.prank(voter);
        governor.castVote(proposalId, 1);
        vm.warp(governor.proposalDeadline(proposalId) + 1);
        bytes32 descHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descHash);
        vm.warp(governor.proposalEta(proposalId));
        governor.execute(targets, values, calldatas, descHash);
    }

    /// @dev An executed proposal now requires the articles gate. The issuer holds the supply in these tests,
    /// so an unbound proposal is checked as qualified and a full For vote passes that placeholder.
    function _ensureArticlesGate(GvGovernor governor) internal {
        if (governor.articlesGate() != address(0)) return;
        address issuer_ = governor.articlesIssuer();
        GvCompanyRules rules = new GvCompanyRules(issuer_);
        GvAssembly assemblyGv = new GvAssembly(issuer_, IERC20(address(governor.token())), rules, governor);
        vm.prank(issuer_);
        governor.setArticlesGate(address(assemblyGv));
    }
}
