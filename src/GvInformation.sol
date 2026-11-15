// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GvAssembly } from "./GvAssembly.sol";
import { GvCompanyRules } from "./GvCompanyRules.sol";

/**
 * @title GvInformation
 * @notice On-chain record of information duties. The document stays off-chain. What is stored here is a
 * keccak256 hash and an optional locator (for example an IPFS CID of a ciphertext). This contract does
 * not accept a document body, does not decrypt anything, and does not store an email address.
 *
 * The board schedules a publication with a deadline and later fulfils it with a hash. A shareholder with
 * a non-zero balance files a request, which starts the response clock from {GvCompanyRules.responseWindow}.
 * That window is a placeholder until counsel replaces it. Overdue duties and requests are queryable.
 * {ResponseOverdue} and {PublicationOverdue} exist so a notifier can turn a poke into a reminder. The
 * poke does not change rights. The view functions are the record.
 */
contract GvInformation {
    struct Duty {
        bytes32 kind;
        uint64 deadline;
        uint64 fulfilledAt;
        bytes32 documentHash;
        string cid;
        bool late;
    }

    struct Request {
        address shareholder;
        bytes32 topicHash;
        string topic;
        uint64 filedAt;
        uint64 responseDeadline;
        uint64 answeredAt;
        bytes32 answerHash;
        string answerCid;
        bool late;
    }

    uint256 public constant MAX_CID = 128;
    uint256 public constant MAX_TOPIC = 200;
    uint256 public constant MAX_PAGE = 50;

    IERC20 public immutable token;
    GvCompanyRules public immutable rules;
    GvAssembly public immutable assembly_;

    uint256 public dutyCount;
    mapping(uint256 id => Duty) private _duties;

    uint256 public requestCount;
    mapping(uint256 id => Request) private _requests;

    error NotDirector(address caller);
    error NotShareholder(address caller);
    error UnknownDuty(uint256 id);
    error UnknownRequest(uint256 id);
    error AlreadyFulfilled(uint256 id);
    error AlreadyAnswered(uint256 id);
    error MissingHash();
    error CidTooLong();
    error TopicTooLong();
    error DeadlineInThePast();
    error EmptyTopic();
    error BadPage();
    error NotOverdue(uint256 id);

    event DocumentScheduled(uint256 indexed dutyId, bytes32 indexed kind, uint64 deadline);
    event DocumentPublished(uint256 indexed dutyId, bytes32 documentHash, string cid, bool late);
    event InformationRequested(
        uint256 indexed requestId, address indexed shareholder, bytes32 topicHash, uint64 responseDeadline
    );
    event InformationAnswered(uint256 indexed requestId, bytes32 answerHash, string cid, bool late);
    event PublicationOverdue(uint256 indexed dutyId, uint64 deadline);
    event ResponseOverdue(uint256 indexed requestId, address indexed shareholder, uint64 responseDeadline);

    constructor(IERC20 token_, GvCompanyRules rules_, GvAssembly assemblyContract) {
        token = token_;
        rules = rules_;
        assembly_ = assemblyContract;
    }

    function duty(uint256 id) external view returns (Duty memory) {
        return _duties[id];
    }

    function request(uint256 id) external view returns (Request memory) {
        return _requests[id];
    }

    function isPublicationOverdue(uint256 id) public view returns (bool) {
        Duty storage item = _duties[id];
        return item.deadline != 0 && item.fulfilledAt == 0 && block.timestamp > item.deadline;
    }

    function isRequestOverdue(uint256 id) public view returns (bool) {
        Request storage item = _requests[id];
        return item.shareholder != address(0) && item.answeredAt == 0 && block.timestamp > item.responseDeadline;
    }

    /// @notice Page of overdue publication ids. `cursor` is the first id to inspect. Ids start at 1.
    function overduePublications(uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextCursor)
    {
        return _page(cursor, limit, true);
    }

    /// @notice Page of overdue information-request ids.
    function overdueRequests(uint256 cursor, uint256 limit)
        external
        view
        returns (uint256[] memory ids, uint256 nextCursor)
    {
        return _page(cursor, limit, false);
    }

    function notifyPublicationOverdue(uint256 id) external {
        if (!isPublicationOverdue(id)) revert NotOverdue(id);
        emit PublicationOverdue(id, _duties[id].deadline);
    }

    function notifyResponseOverdue(uint256 id) external {
        if (!isRequestOverdue(id)) revert NotOverdue(id);
        emit ResponseOverdue(id, _requests[id].shareholder, _requests[id].responseDeadline);
    }

    function schedulePublication(bytes32 kind, uint64 deadline) external returns (uint256 id) {
        if (!assembly_.isDirector(msg.sender)) revert NotDirector(msg.sender);
        if (kind == bytes32(0)) revert MissingHash();
        if (deadline <= block.timestamp) revert DeadlineInThePast();
        id = ++dutyCount;
        Duty storage item = _duties[id];
        item.kind = kind;
        item.deadline = deadline;
        emit DocumentScheduled(id, kind, deadline);
    }

    /// @param documentHash Keccak of the off-chain document. Store ciphertext if the document is confidential.
    /// @param cid Optional locator. Empty is allowed. This is not the document.
    function fulfillPublication(uint256 id, bytes32 documentHash, string calldata cid) external {
        if (!assembly_.isDirector(msg.sender)) revert NotDirector(msg.sender);
        Duty storage item = _duties[id];
        if (item.deadline == 0) revert UnknownDuty(id);
        if (item.fulfilledAt != 0) revert AlreadyFulfilled(id);
        if (documentHash == bytes32(0)) revert MissingHash();
        if (bytes(cid).length > MAX_CID) revert CidTooLong();
        item.fulfilledAt = uint64(block.timestamp);
        item.documentHash = documentHash;
        item.cid = cid;
        item.late = block.timestamp > item.deadline;
        emit DocumentPublished(id, documentHash, cid, item.late);
    }

    function fileRequest(bytes32 topicHash, string calldata topic) external returns (uint256 id) {
        if (token.balanceOf(msg.sender) == 0) revert NotShareholder(msg.sender);
        if (topicHash == bytes32(0)) revert MissingHash();
        uint256 topicLength = bytes(topic).length;
        if (topicLength == 0) revert EmptyTopic();
        if (topicLength > MAX_TOPIC) revert TopicTooLong();
        id = ++requestCount;
        Request storage item = _requests[id];
        item.shareholder = msg.sender;
        item.topicHash = topicHash;
        item.topic = topic;
        item.filedAt = uint64(block.timestamp);
        item.responseDeadline = uint64(block.timestamp) + rules.responseWindow();
        emit InformationRequested(id, msg.sender, topicHash, item.responseDeadline);
    }

    function answerRequest(uint256 id, bytes32 answerHash, string calldata cid) external {
        if (!assembly_.isDirector(msg.sender)) revert NotDirector(msg.sender);
        Request storage item = _requests[id];
        if (item.shareholder == address(0)) revert UnknownRequest(id);
        if (item.answeredAt != 0) revert AlreadyAnswered(id);
        if (answerHash == bytes32(0)) revert MissingHash();
        if (bytes(cid).length > MAX_CID) revert CidTooLong();
        item.answeredAt = uint64(block.timestamp);
        item.answerHash = answerHash;
        item.answerCid = cid;
        item.late = block.timestamp > item.responseDeadline;
        emit InformationAnswered(id, answerHash, cid, item.late);
    }

    function _page(uint256 cursor, uint256 limit, bool publications)
        private
        view
        returns (uint256[] memory ids, uint256 nextCursor)
    {
        if (limit == 0 || limit > MAX_PAGE) revert BadPage();
        uint256 count = publications ? dutyCount : requestCount;
        uint256 start = cursor == 0 ? 1 : cursor;
        uint256[] memory tmp = new uint256[](limit);
        uint256 found;
        uint256 i = start;
        for (; i <= count && found < limit; ++i) {
            bool overdue = publications ? isPublicationOverdue(i) : isRequestOverdue(i);
            if (overdue) tmp[found++] = i;
        }
        ids = new uint256[](found);
        for (uint256 j; j < found; ++j) {
            ids[j] = tmp[j];
        }
        nextCursor = i;
    }
}
