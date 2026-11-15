// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GvAssembly } from "./GvAssembly.sol";
import { GvCompanyRules } from "./GvCompanyRules.sol";
import { GvShare } from "./GvShare.sol";
import { GvShareTerms } from "./GvShareTerms.sol";
import { IGvShareModule } from "./interfaces/IGvSharePolicy.sol";

/**
 * @title GvRecovery
 * @notice Time-delayed forced transfer for a lost key or a court order.
 *
 * This is not a general admin backdoor. There is no function that moves an arbitrary balance at the
 * caller's choice. A director proposes one transfer, from one address, to one address, for one amount
 * (or the full balance, if the amount is zero), and commits a keccak256 of the board resolution or of
 * the court order. The document stays off-chain. The contract does not verify it. The delay cannot be
 * shorter than {GvCompanyRules.MIN_RECOVERY_DELAY}, which is a software floor, not a statutory period.
 *
 * A board-resolution recovery (courtOrder = false) can be cancelled by the affected holder, by a
 * director, or by the kit timelock. A court-order recovery cannot be cancelled by the affected holder.
 * The timelock and a director still can, before execution. Execution is permissionless once the delay
 * has passed and enough directors have signed. The configured signature count is a placeholder.
 *
 * Design reference, not a copy: a public recovery note that a forced move should be announced and
 * delayed rather than silent. The implementation here is a board or court-hash path, not that code.
 */
contract GvRecovery is IGvShareModule {
    struct Recovery {
        address from;
        address to;
        uint256 amount;
        bytes32 orderHash;
        bool courtOrder;
        address proposer;
        uint64 executeAfter;
        uint256 signatures;
        bool executed;
        bool cancelled;
    }

    GvShare public immutable token;
    GvCompanyRules public immutable rules;
    GvShareTerms public immutable terms;
    GvAssembly public immutable assembly_;
    address public immutable timelock;

    uint256 public recoveryCount;
    mapping(uint256 id => Recovery) private _recoveries;
    mapping(uint256 id => mapping(address director => bool)) public signed;

    address private _forceFrom;
    address private _forceTo;
    uint256 private _forceAmount;

    error ZeroAddress();
    error NotDirector(address caller);
    error NotTimelock(address caller);
    error UnknownRecovery(uint256 id);
    error RecoveryClosed(uint256 id);
    error MissingHash();
    error SameAddress();
    error TooEarly(uint256 id, uint64 executeAfter);
    error NeedSignatures(uint256 have, uint256 need);
    error AlreadySigned(address director);
    error HolderCannotCancelCourtOrder();
    error NotHolder(address caller);
    error RecipientNotEligible(address to);
    error InsufficientBalance(uint256 balance, uint256 amount);
    error NothingToRecover(address from);

    event RecoveryProposed(
        uint256 indexed id,
        address indexed from,
        address indexed to,
        uint256 amount,
        bytes32 orderHash,
        bool courtOrder,
        uint64 executeAfter
    );
    event RecoveryCosigned(uint256 indexed id, address indexed director, uint256 signatures);
    event RecoveryCancelled(uint256 indexed id, address indexed by);
    event RecoveryExecuted(
        uint256 indexed id, address indexed from, address indexed to, uint256 amount, bytes32 orderHash, bool courtOrder
    );

    constructor(
        GvShare token_,
        GvCompanyRules rules_,
        GvShareTerms terms_,
        GvAssembly assemblyContract,
        address timelock_
    ) {
        if (
            address(token_) == address(0) || address(rules_) == address(0) || address(terms_) == address(0)
                || address(assemblyContract) == address(0) || timelock_ == address(0)
        ) revert ZeroAddress();
        token = token_;
        rules = rules_;
        terms = terms_;
        assembly_ = assemblyContract;
        timelock = timelock_;
    }

    function recovery(uint256 id) external view returns (Recovery memory) {
        return _recoveries[id];
    }

    function mayForceTransfer(address from, address to, uint256 amount) external view returns (bool) {
        return from == _forceFrom && to == _forceTo && amount == _forceAmount && amount != 0;
    }

    /**
     * @param amount Pass zero to move the balance held at execution. A non-zero amount is exact.
     * @param orderHash Keccak of the board minutes or of the court order. Required. Not checked against the file.
     * @param courtOrder True only when the hash commits a court order. False is a board resolution.
     */
    function proposeRecovery(address from, address to, uint256 amount, bytes32 orderHash, bool courtOrder)
        external
        returns (uint256 id)
    {
        if (!assembly_.isDirector(msg.sender)) revert NotDirector(msg.sender);
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        if (from == to) revert SameAddress();
        if (orderHash == bytes32(0)) revert MissingHash();
        if (!courtOrder) _checkRecipient(to);
        id = ++recoveryCount;
        Recovery storage item = _recoveries[id];
        item.from = from;
        item.to = to;
        item.amount = amount;
        item.orderHash = orderHash;
        item.courtOrder = courtOrder;
        item.proposer = msg.sender;
        item.executeAfter = uint64(block.timestamp) + rules.recoveryDelay();
        item.signatures = 1;
        signed[id][msg.sender] = true;
        emit RecoveryProposed(id, from, to, amount, orderHash, courtOrder, item.executeAfter);
    }

    function cosignRecovery(uint256 id) external {
        if (!assembly_.isDirector(msg.sender)) revert NotDirector(msg.sender);
        Recovery storage item = _recoveries[id];
        if (item.proposer == address(0)) revert UnknownRecovery(id);
        if (item.executed || item.cancelled) revert RecoveryClosed(id);
        if (signed[id][msg.sender]) revert AlreadySigned(msg.sender);
        signed[id][msg.sender] = true;
        item.signatures += 1;
        emit RecoveryCosigned(id, msg.sender, item.signatures);
    }

    function cancelRecovery(uint256 id) external {
        Recovery storage item = _recoveries[id];
        if (item.proposer == address(0)) revert UnknownRecovery(id);
        if (item.executed || item.cancelled) revert RecoveryClosed(id);
        bool boardOrTimelock = msg.sender == timelock || assembly_.isDirector(msg.sender);
        if (!boardOrTimelock && msg.sender == item.from && item.courtOrder) revert HolderCannotCancelCourtOrder();
        if (!boardOrTimelock && msg.sender != item.from) revert NotHolder(msg.sender);
        item.cancelled = true;
        emit RecoveryCancelled(id, msg.sender);
    }

    function executeRecovery(uint256 id) external {
        Recovery storage item = _recoveries[id];
        if (item.proposer == address(0)) revert UnknownRecovery(id);
        if (item.executed || item.cancelled) revert RecoveryClosed(id);
        if (block.timestamp < item.executeAfter) revert TooEarly(id, item.executeAfter);
        uint256 need = rules.recoverySignatures();
        if (item.signatures < need) revert NeedSignatures(item.signatures, need);
        uint256 balance = token.balanceOf(item.from);
        uint256 amount = item.amount == 0 ? balance : item.amount;
        if (amount == 0) revert NothingToRecover(item.from);
        if (balance < amount) revert InsufficientBalance(balance, amount);
        if (!item.courtOrder) _checkRecipient(item.to);
        item.executed = true;
        _force(item.from, item.to, amount);
        emit RecoveryExecuted(id, item.from, item.to, amount, item.orderHash, item.courtOrder);
    }

    function _checkRecipient(address to) private view {
        if (!terms.whitelisted(to) || !terms.holdsCurrentSha(to)) revert RecipientNotEligible(to);
    }

    function _force(address from, address to, uint256 amount) private {
        _forceFrom = from;
        _forceTo = to;
        _forceAmount = amount;
        token.moduleTransfer(from, to, amount);
        _forceFrom = address(0);
        _forceTo = address(0);
        _forceAmount = 0;
    }
}
