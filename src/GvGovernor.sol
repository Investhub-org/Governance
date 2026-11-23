// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Governor } from "@openzeppelin/contracts/governance/Governor.sol";
import { GovernorSettings } from "@openzeppelin/contracts/governance/extensions/GovernorSettings.sol";
import { GovernorCountingSimple } from "@openzeppelin/contracts/governance/extensions/GovernorCountingSimple.sol";
import { GovernorVotes } from "@openzeppelin/contracts/governance/extensions/GovernorVotes.sol";
import {
    GovernorVotesQuorumFraction
} from "@openzeppelin/contracts/governance/extensions/GovernorVotesQuorumFraction.sol";
import { GovernorTimelockControl } from "@openzeppelin/contracts/governance/extensions/GovernorTimelockControl.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";

/**
 * @title GvGovernor
 * @notice OpenZeppelin Governor, wired the way the Contracts Wizard wires a timelocked governor
 * so Tally can index it. Modules, and only these modules:
 *
 * - {Governor}
 * - {GovernorSettings} (delay, period, proposal threshold; changeable only by an executed proposal)
 * - {GovernorCountingSimple} (Against / For / Abstain, Bravo ordering)
 * - {GovernorVotes} (any ERC-5805 token; the clock is the token's ERC-6372 clock)
 * - {GovernorVotesQuorumFraction} (quorum is `numerator / 100` of past total supply)
 * - {GovernorTimelockControl}
 *
 * Counting mode is `support=bravo&quorum=for,abstain`. For must be strictly greater than Against,
 * and For + Abstain must reach quorum. Against does not count toward quorum.
 *
 * This contract stays the OpenZeppelin wizard shape Tally indexes: one quorum numerator, and no
 * copy of the articles formula. Execution is the extra check. {articlesGate} points at the meeting
 * contract. {_executeOperations} asks that contract before the timelock runs. When the company
 * rules' binding mode is Articles or Both, the gate calls {GvCompanyRules.canonicalOutcome} and
 * reverts unless `passed` is true. Governor mode does not add that check. The governor's own
 * vote can still succeed while the articles formula fails; the timelock does not run in that case
 * unless the mode is Governor.
 *
 * An unbound proposal is checked as a qualified resolution. Binding it to an agenda item uses the
 * strictest class it was bound to. The issuer recorded by the factory sets the gate once. The factory
 * may set it in that same deployment transaction, then the wiring right is cleared. After the gate
 * is set, only the timelock can replace it, and that replacement is itself checked by the current gate.
 *
 * The clock is not hardcoded here. It follows the votes token. Kit tokens use `mode=timestamp`,
 * so delay and period are seconds. There is no owner. The executor is the timelock.
 *
 * `updateTimelock` remains the OpenZeppelin function: only an executed proposal can call it.
 * The share minter and the dividend contract keep the original timelock address. Pointing this
 * governor at a new timelock does not move those rights.
 */
interface IArticlesGate {
    function assertExecutable(uint256 proposalId) external view;
}

contract GvGovernor is
    Governor,
    GovernorSettings,
    GovernorCountingSimple,
    GovernorVotes,
    GovernorVotesQuorumFraction,
    GovernorTimelockControl
{
    /// @notice The factory records the issuer in the deploy transaction. Direct deployments can call this once too.
    address public articlesIssuer;
    /// @notice Meeting contract that reads {GvCompanyRules.canonicalOutcome}. Zero blocks execution.
    address public articlesGate;
    /// @notice Caller of {recognizeIssuer}, cleared when the gate is set or when that caller renounces.
    /// The factory uses it inside {GvKitFactory.deploySet} and renounces it on a kit-only deploy.
    address public articlesWirer;

    error ArticlesIssuerAlreadySet();
    error ArticlesIssuerZero();
    error NotArticlesIssuer(address caller);
    error NotArticlesTimelock(address caller);
    error ArticlesGateZero();
    error ArticlesGateUnset();

    event ArticlesIssuerRecognized(address indexed issuer);
    event ArticlesGateSet(address indexed gate);
    event ArticlesWirerCleared(address indexed wirer);
    constructor(
        string memory name_,
        IVotes token_,
        TimelockController timelock_,
        uint48 votingDelay_,
        uint32 votingPeriod_,
        uint256 proposalThreshold_,
        uint256 quorumNumerator_
    )
        Governor(name_)
        GovernorSettings(votingDelay_, votingPeriod_, proposalThreshold_)
        GovernorVotes(token_)
        GovernorVotesQuorumFraction(quorumNumerator_)
        GovernorTimelockControl(timelock_)
    { }

    /// @notice Once. The factory calls this in the same transaction as deployment.
    function recognizeIssuer(address issuer_) external {
        if (articlesIssuer != address(0)) revert ArticlesIssuerAlreadySet();
        if (issuer_ == address(0)) revert ArticlesIssuerZero();
        articlesIssuer = issuer_;
        articlesWirer = msg.sender;
        emit ArticlesIssuerRecognized(issuer_);
    }

    /// @notice Drop the one-time wiring right. The factory calls this when it does not deploy modules.
    function renounceArticlesWirer() external {
        if (msg.sender != articlesWirer) revert NotArticlesIssuer(msg.sender);
        _clearWirer();
    }

    /**
     * @notice Point execution at the meeting contract. The issuer, or the one-time wirer, can set it
     * while it is unset. The wirer is cleared in that call. After that, only the timelock can replace
     * it, which means an executed proposal, and that proposal is checked by the gate already stored.
     */
    function setArticlesGate(address gate) external {
        if (gate == address(0)) revert ArticlesGateZero();
        if (articlesGate == address(0)) {
            if (msg.sender != articlesIssuer && msg.sender != articlesWirer) revert NotArticlesIssuer(msg.sender);
            _clearWirer();
        } else if (msg.sender != _executor()) {
            revert NotArticlesTimelock(msg.sender);
        }
        articlesGate = gate;
        emit ArticlesGateSet(gate);
    }

    function _clearWirer() private {
        address wirer = articlesWirer;
        if (wirer == address(0)) return;
        articlesWirer = address(0);
        emit ArticlesWirerCleared(wirer);
    }

    function quorum(uint256 timepoint) public view override(Governor, GovernorVotesQuorumFraction) returns (uint256) {
        return super.quorum(timepoint);
    }

    function state(uint256 proposalId) public view override(Governor, GovernorTimelockControl) returns (ProposalState) {
        return super.state(proposalId);
    }

    function proposalThreshold() public view override(Governor, GovernorSettings) returns (uint256) {
        return super.proposalThreshold();
    }

    function proposalNeedsQueuing(uint256 proposalId)
        public
        view
        override(Governor, GovernorTimelockControl)
        returns (bool)
    {
        return super.proposalNeedsQueuing(proposalId);
    }

    function _queueOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint48) {
        return super._queueOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _executeOperations(
        uint256 proposalId,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) {
        address gate = articlesGate;
        if (gate == address(0)) revert ArticlesGateUnset();
        IArticlesGate(gate).assertExecutable(proposalId);
        super._executeOperations(proposalId, targets, values, calldatas, descriptionHash);
    }

    function _cancel(
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        bytes32 descriptionHash
    ) internal override(Governor, GovernorTimelockControl) returns (uint256) {
        return super._cancel(targets, values, calldatas, descriptionHash);
    }

    function _executor() internal view override(Governor, GovernorTimelockControl) returns (address) {
        return super._executor();
    }
}
