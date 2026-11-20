// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { IVotes } from "@openzeppelin/contracts/governance/utils/IVotes.sol";
import { GvCompanyRules } from "./GvCompanyRules.sol";
import { GvGovernor } from "./GvGovernor.sol";

/**
 * @title GvAssembly
 * @notice General meeting record for one issuer: AGM or EGM, notice, who convened, an on-chain agenda,
 * and the hash of the invitation document. The governor remains the ballot. This contract does not
 * replace it and does not hold tokens.
 *
 * An off-chain notifier turns {InvitationNotice} into email. The event carries the meeting id, the type,
 * the notice deadline, the invitation hash, and an optional IPFS CID. It carries no email address and no
 * member list. The notifier reads holders from the share token and addresses from the issuer's own
 * register, which stays off-chain.
 *
 * Who may convene comes from {GvCompanyRules}: a director, while the board meets the configured minimum,
 * or shareholders whose balances meet the configured fraction of supply. A single holder at or above the
 * fraction may convene alone. Holders below it file a request and convene once the combined current
 * balances still meet the fraction. Support is re-read at convening time, so shares that moved no longer count.
 *
 * The notice period is stored on the meeting when it is convened. A later change to the rules does not
 * shorten a notice that was already given. The meeting cannot be opened before that deadline.
 */
contract GvAssembly is Ownable {
    enum Phase {
        None,
        Convened,
        Open,
        Closed
    }

    struct AgendaItem {
        string title;
        bytes32 documentHash;
        GvCompanyRules.ResolutionClass class;
    }

    struct Meeting {
        GvCompanyRules.MeetingType meetingType;
        address convener;
        bool convenedByBoard;
        Phase phase;
        uint64 convenedAt;
        uint64 noticeDeadline;
        bytes32 invitationHash;
        bytes32 agendaHash;
        string invitationCid;
    }

    struct ConveningRequest {
        GvCompanyRules.MeetingType meetingType;
        address initiator;
        uint64 expiresAt;
        bytes32 invitationHash;
        bytes32 agendaHash;
        string invitationCid;
        bool convened;
        bool cancelled;
        uint256 meetingId;
    }

    uint256 public constant MAX_AGENDA = 16;
    uint256 public constant MAX_TITLE = 120;
    uint256 public constant MAX_CID = 128;
    uint256 public constant MAX_SUPPORTERS = 64;

    IERC20 public immutable token;
    GvCompanyRules public immutable rules;
    GvGovernor public immutable governor;

    mapping(address account => bool) public isDirector;
    uint256 public directorCount;

    uint256 public meetingCount;
    mapping(uint256 meetingId => Meeting) private _meetings;
    mapping(uint256 meetingId => AgendaItem[]) private _agenda;
    mapping(uint256 meetingId => mapping(uint256 item => uint256 proposalId)) public boundProposal;

    uint256 public requestCount;
    mapping(uint256 requestId => ConveningRequest) private _requests;
    mapping(uint256 requestId => AgendaItem[]) private _requestAgenda;
    mapping(uint256 requestId => address[]) private _supporters;
    mapping(uint256 requestId => mapping(address account => uint256 amount)) public pledged;

    error ZeroAddress();
    error TokenMismatch();
    error NotDirector(address caller);
    error BoardBelowMinimum(uint256 directors, uint256 required);
    error MissingInvitation();
    error CidTooLong();
    error EmptyAgenda();
    error AgendaTooLong();
    error EmptyTitle();
    error TitleTooLong();
    error MissingDocument();
    error ThresholdNotMet(uint256 support, uint256 supply);
    error UnknownMeeting(uint256 meetingId);
    error UnknownRequest(uint256 requestId);
    error WrongPhase(uint256 meetingId);
    error NoticeNotElapsed(uint256 meetingId, uint64 noticeDeadline);
    error RequestExpired(uint256 requestId);
    error RequestClosed(uint256 requestId);
    error NoShares(address account);
    error AlreadySupported(address account);
    error TooManySupporters();
    error UnknownItem(uint256 meetingId, uint256 index);
    error ProposalAlreadyBound(uint256 meetingId, uint256 index);
    error NotHolder(address caller);
    error NotConvener(address caller);

    event DirectorSet(address indexed account, bool allowed, uint256 directorCount);
    event MeetingConvened(
        uint256 indexed meetingId,
        GvCompanyRules.MeetingType indexed meetingType,
        address indexed convener,
        bool convenedByBoard,
        uint64 noticeDeadline,
        bytes32 invitationHash,
        bytes32 agendaHash
    );
    /**
     * @notice Notifier input. Subscribe to this event. Join it off-chain to the share token's holders.
     * Do not expect an email address in the log. The CID is a locator for a document that lives off-chain.
     * `invitationHash` is the keccak256 of that document, or another commitment the issuer published.
     */
    event InvitationNotice(
        uint256 indexed meetingId,
        uint8 indexed meetingType,
        address indexed convener,
        bool convenedByBoard,
        uint64 noticeDeadline,
        bytes32 invitationHash,
        string invitationCid,
        bytes32 agendaHash
    );
    event MeetingOpened(uint256 indexed meetingId);
    event MeetingClosed(uint256 indexed meetingId);
    event MeetingCancelled(uint256 indexed meetingId, address indexed by);
    event ConveningRequested(uint256 indexed requestId, address indexed initiator, uint256 pledged);
    event ConveningSupported(uint256 indexed requestId, address indexed account, uint256 pledged);
    event ProposalBound(
        uint256 indexed meetingId,
        uint256 indexed itemIndex,
        uint256 indexed proposalId,
        GvCompanyRules.ResolutionClass class
    );

    constructor(address issuer, IERC20 token_, GvCompanyRules rules_, GvGovernor governor_) Ownable(issuer) {
        if (address(token_) == address(0) || address(rules_) == address(0) || address(governor_) == address(0)) {
            revert ZeroAddress();
        }
        if (address(governor_.token()) != address(token_)) revert TokenMismatch();
        token = token_;
        rules = rules_;
        governor = governor_;
    }

    function boardMeetsRules() public view returns (bool) {
        return directorCount >= rules.requiredDirectors();
    }

    function meeting(uint256 meetingId) external view returns (Meeting memory) {
        return _meetings[meetingId];
    }

    function agendaLength(uint256 meetingId) external view returns (uint256) {
        return _agenda[meetingId].length;
    }

    function agendaItem(uint256 meetingId, uint256 index) external view returns (AgendaItem memory) {
        return _agenda[meetingId][index];
    }

    function request(uint256 requestId) external view returns (ConveningRequest memory) {
        return _requests[requestId];
    }

    function supporterCount(uint256 requestId) external view returns (uint256) {
        return _supporters[requestId].length;
    }

    /// @notice Sum of each supporter's current balance, capped by what they pledged. Moved shares drop out.
    function supportOf(uint256 requestId) public view returns (uint256 total) {
        address[] storage list = _supporters[requestId];
        uint256 n = list.length;
        for (uint256 i; i < n; ++i) {
            address account = list[i];
            uint256 amount = pledged[requestId][account];
            uint256 balance = token.balanceOf(account);
            total += balance < amount ? balance : amount;
        }
    }

    function hashAgenda(AgendaItem[] calldata agenda) external pure returns (bytes32) {
        return keccak256(abi.encode(agenda));
    }

    /// @notice Owner is the issuer, or the timelock after ownership is transferred. Not a hidden operator.
    function setDirector(address account, bool allowed) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        if (isDirector[account] == allowed) return;
        if (!allowed) {
            uint256 required = rules.requiredDirectors();
            uint256 next = directorCount - 1;
            if (next < required) revert BoardBelowMinimum(next, required);
            directorCount = next;
        } else {
            directorCount += 1;
        }
        isDirector[account] = allowed;
        emit DirectorSet(account, allowed, directorCount);
    }

    function conveneByBoard(
        GvCompanyRules.MeetingType meetingType,
        bytes32 invitationHash,
        string calldata invitationCid,
        AgendaItem[] calldata agenda
    ) external returns (uint256 meetingId) {
        if (!isDirector[msg.sender]) revert NotDirector(msg.sender);
        uint256 required = rules.requiredDirectors();
        if (directorCount < required) revert BoardBelowMinimum(directorCount, required);
        return _convene(msg.sender, meetingType, true, invitationHash, invitationCid, agenda);
    }

    function conveneByShareholders(
        GvCompanyRules.MeetingType meetingType,
        bytes32 invitationHash,
        string calldata invitationCid,
        AgendaItem[] calldata agenda
    ) external returns (uint256 meetingId) {
        uint256 supply = token.totalSupply();
        uint256 balance = token.balanceOf(msg.sender);
        if (!rules.meetsShareThreshold(balance, supply, rules.meetingCallThresholdBps())) {
            revert ThresholdNotMet(balance, supply);
        }
        return _convene(msg.sender, meetingType, false, invitationHash, invitationCid, agenda);
    }

    function fileConveningRequest(
        GvCompanyRules.MeetingType meetingType,
        bytes32 invitationHash,
        string calldata invitationCid,
        AgendaItem[] calldata agenda
    ) external returns (uint256 requestId) {
        _checkInvitation(invitationHash, invitationCid);
        _checkAgenda(agenda);
        uint256 balance = token.balanceOf(msg.sender);
        if (balance == 0) revert NoShares(msg.sender);
        requestId = ++requestCount;
        ConveningRequest storage filed = _requests[requestId];
        filed.meetingType = meetingType;
        filed.initiator = msg.sender;
        filed.expiresAt = uint64(block.timestamp) + rules.conveningRequestTtl();
        filed.invitationHash = invitationHash;
        filed.invitationCid = invitationCid;
        filed.agendaHash = keccak256(abi.encode(agenda));
        _writeAgenda(_requestAgenda[requestId], agenda);
        _pledge(requestId, msg.sender, balance);
        emit ConveningRequested(requestId, msg.sender, balance);
    }

    function supportConveningRequest(uint256 requestId) external {
        ConveningRequest storage filed = _requests[requestId];
        if (filed.initiator == address(0)) revert UnknownRequest(requestId);
        if (filed.convened || filed.cancelled) revert RequestClosed(requestId);
        if (block.timestamp > filed.expiresAt) revert RequestExpired(requestId);
        if (pledged[requestId][msg.sender] != 0) revert AlreadySupported(msg.sender);
        uint256 balance = token.balanceOf(msg.sender);
        if (balance == 0) revert NoShares(msg.sender);
        if (_supporters[requestId].length >= MAX_SUPPORTERS) revert TooManySupporters();
        _pledge(requestId, msg.sender, balance);
        emit ConveningSupported(requestId, msg.sender, balance);
    }

    function conveneFromRequest(uint256 requestId) external returns (uint256 meetingId) {
        ConveningRequest storage filed = _requests[requestId];
        if (filed.initiator == address(0)) revert UnknownRequest(requestId);
        if (filed.convened || filed.cancelled) revert RequestClosed(requestId);
        if (block.timestamp > filed.expiresAt) revert RequestExpired(requestId);
        uint256 supply = token.totalSupply();
        uint256 support = supportOf(requestId);
        if (!rules.meetsShareThreshold(support, supply, rules.meetingCallThresholdBps())) {
            revert ThresholdNotMet(support, supply);
        }
        meetingId = _createMeeting(
            filed.initiator, filed.meetingType, false, filed.invitationHash, filed.invitationCid, filed.agendaHash
        );
        _copyAgenda(requestId, meetingId);
        filed.convened = true;
        filed.meetingId = meetingId;
    }

    function openMeeting(uint256 meetingId) external {
        Meeting storage current = _meetings[meetingId];
        if (current.convener == address(0)) revert UnknownMeeting(meetingId);
        if (current.phase != Phase.Convened) revert WrongPhase(meetingId);
        if (block.timestamp < current.noticeDeadline) revert NoticeNotElapsed(meetingId, current.noticeDeadline);
        current.phase = Phase.Open;
        emit MeetingOpened(meetingId);
    }

    function closeMeeting(uint256 meetingId) external {
        Meeting storage current = _meetings[meetingId];
        if (current.phase != Phase.Open) revert WrongPhase(meetingId);
        if (!isDirector[msg.sender] && msg.sender != current.convener) revert NotConvener(msg.sender);
        current.phase = Phase.Closed;
        emit MeetingClosed(meetingId);
    }

    function cancelMeeting(uint256 meetingId) external {
        Meeting storage current = _meetings[meetingId];
        if (current.phase != Phase.Convened) revert WrongPhase(meetingId);
        if (!isDirector[msg.sender] && msg.sender != current.convener) revert NotConvener(msg.sender);
        current.phase = Phase.Closed;
        emit MeetingCancelled(meetingId, msg.sender);
    }

    /// @notice Link a governor proposal to an agenda item. Any current holder may file the link once the meeting is open.
    function bindProposal(uint256 meetingId, uint256 itemIndex, uint256 proposalId) external {
        Meeting storage current = _meetings[meetingId];
        if (current.phase != Phase.Open && current.phase != Phase.Closed) revert WrongPhase(meetingId);
        if (itemIndex >= _agenda[meetingId].length) revert UnknownItem(meetingId, itemIndex);
        if (token.balanceOf(msg.sender) == 0) revert NotHolder(msg.sender);
        if (boundProposal[meetingId][itemIndex] != 0) revert ProposalAlreadyBound(meetingId, itemIndex);
        if (governor.proposalProposer(proposalId) == address(0)) revert UnknownItem(meetingId, itemIndex);
        boundProposal[meetingId][itemIndex] = proposalId;
        emit ProposalBound(meetingId, itemIndex, proposalId, _agenda[meetingId][itemIndex].class);
    }

    /**
     * @notice Articles check for one agenda item. Quorum is participation (for + against + abstain) against
     * the votes token's past total supply. Majority is for-votes against for+against, strictly above the
     * configured fraction. Abstain counts toward quorum only.
     *
     * This uses delegated voting weight because that is what the governor recorded. Whether the PGR or the
     * articles instead count every share, including undelegated shares, as present or absent is a question
     * for counsel. The numbers themselves are the placeholders or the values the owner stored.
     */
    function articlesOutcome(uint256 meetingId, uint256 itemIndex, uint256 proposalId)
        external
        view
        returns (
            bool quorumReached,
            bool majorityReached,
            uint256 forVotes,
            uint256 againstVotes,
            uint256 abstainVotes,
            uint256 supply
        )
    {
        if (itemIndex >= _agenda[meetingId].length) revert UnknownItem(meetingId, itemIndex);
        GvCompanyRules.ClassRule memory rule = rules.classRule(_agenda[meetingId][itemIndex].class);
        (againstVotes, forVotes, abstainVotes) = governor.proposalVotes(proposalId);
        uint256 snapshot = governor.proposalSnapshot(proposalId);
        supply = IVotes(address(token)).getPastTotalSupply(snapshot);
        uint256 participation = forVotes + againstVotes + abstainVotes;
        quorumReached = rules.quorumMet(participation, supply, rule.quorumBps);
        majorityReached = rules.majorityMet(forVotes, againstVotes, rule.majorityBps);
    }

    function _convene(
        address convener,
        GvCompanyRules.MeetingType meetingType,
        bool byBoard,
        bytes32 invitationHash,
        string calldata invitationCid,
        AgendaItem[] calldata agenda
    ) private returns (uint256 meetingId) {
        _checkInvitation(invitationHash, invitationCid);
        _checkAgenda(agenda);
        bytes32 agendaHash = keccak256(abi.encode(agenda));
        meetingId = _createMeeting(convener, meetingType, byBoard, invitationHash, invitationCid, agendaHash);
        _writeAgenda(_agenda[meetingId], agenda);
    }

    function _createMeeting(
        address convener,
        GvCompanyRules.MeetingType meetingType,
        bool byBoard,
        bytes32 invitationHash,
        string memory invitationCid,
        bytes32 agendaHash
    ) private returns (uint256 meetingId) {
        uint64 noticeDeadline = uint64(block.timestamp) + rules.noticePeriod(meetingType);
        meetingId = ++meetingCount;
        Meeting storage created = _meetings[meetingId];
        created.meetingType = meetingType;
        created.convener = convener;
        created.convenedByBoard = byBoard;
        created.phase = Phase.Convened;
        created.convenedAt = uint64(block.timestamp);
        created.noticeDeadline = noticeDeadline;
        created.invitationHash = invitationHash;
        created.agendaHash = agendaHash;
        created.invitationCid = invitationCid;
        emit MeetingConvened(meetingId, meetingType, convener, byBoard, noticeDeadline, invitationHash, agendaHash);
        emit InvitationNotice(
            meetingId, uint8(meetingType), convener, byBoard, noticeDeadline, invitationHash, invitationCid, agendaHash
        );
    }

    function _copyAgenda(uint256 requestId, uint256 meetingId) private {
        AgendaItem[] storage source = _requestAgenda[requestId];
        AgendaItem[] storage dest = _agenda[meetingId];
        uint256 n = source.length;
        for (uint256 i; i < n; ++i) {
            dest.push(source[i]);
        }
    }

    function _writeAgenda(AgendaItem[] storage dest, AgendaItem[] calldata agenda) private {
        uint256 n = agenda.length;
        for (uint256 i; i < n; ++i) {
            dest.push(agenda[i]);
        }
    }

    function _pledge(uint256 requestId, address account, uint256 amount) private {
        pledged[requestId][account] = amount;
        _supporters[requestId].push(account);
    }

    function _checkInvitation(bytes32 invitationHash, string calldata invitationCid) private pure {
        if (invitationHash == bytes32(0)) revert MissingInvitation();
        if (bytes(invitationCid).length > MAX_CID) revert CidTooLong();
    }

    function _checkAgenda(AgendaItem[] calldata agenda) private pure {
        uint256 n = agenda.length;
        if (n == 0) revert EmptyAgenda();
        if (n > MAX_AGENDA) revert AgendaTooLong();
        for (uint256 i; i < n; ++i) {
            uint256 titleLength = bytes(agenda[i].title).length;
            if (titleLength == 0) revert EmptyTitle();
            if (titleLength > MAX_TITLE) revert TitleTooLong();
            if (agenda[i].documentHash == bytes32(0)) revert MissingDocument();
        }
    }
}
