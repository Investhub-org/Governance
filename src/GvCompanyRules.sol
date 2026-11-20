// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";

/**
 * @title GvCompanyRules
 * @notice Parameter store for one issuer. The issuer is the owner. InvestHub has no role.
 * The owner should be transferred to the kit timelock once the figures are the ones counsel approved,
 * so later changes are executed proposals. Until that transfer, the issuer key can retune every figure.
 *
 * PLACEHOLDER DEFAULTS.
 * Every number this contract stores at deployment is a software placeholder. It is not a statement of
 * the Liechtenstein Personen- und Gesellschaftsrecht (PGR), the TVTG, or of any company's articles.
 * A Liechtenstein lawyer has to replace each one with the figure the articles and the statute require
 * before an issuer relies on it. Do not read a placeholder as a legal fact.
 *
 * {canonicalOutcome} is the one function the articles reference. {GvAssembly.articlesOutcome} calls it
 * and does not keep a second copy of the formula. {BindingMode} selects which formula `passed` uses.
 *
 * {GvGovernor} is a different contract and is left unchanged. It is the execution gate Tally indexes,
 * with one quorum numerator for every proposal, counting For and Abstain. It does not read this store.
 * A proposal can execute there while `passed` here is false. Setting the mode to {BindingMode.Both}
 * makes the articles require both formulas. It still does not stop the governor from executing.
 */
contract GvCompanyRules is Ownable {
    enum ResolutionClass {
        Ordinary,
        Qualified
    }

    enum MeetingType {
        AGM,
        EGM
    }

    /**
     * @notice Which formula {canonicalOutcome} treats as the articles' decision.
     * - Articles: participation quorum, and For against For+Against. Abstain counts only toward quorum.
     * - Governor: the governor's shape (For+Abstain quorum, For strictly above Against), using this
     *   class's basis points and not the governor contract's percent numerator.
     * - Both: both formulas must succeed.
     */
    enum BindingMode {
        Articles,
        Governor,
        Both
    }

    struct ResolutionOutcome {
        bool passed;
        bool articlesQuorum;
        bool articlesMajority;
        bool bravoQuorum;
        bool bravoMajority;
        uint256 forVotes;
        uint256 againstVotes;
        uint256 abstainVotes;
        uint256 supply;
    }

    struct ClassRule {
        uint16 quorumBps;
        uint16 majorityBps;
    }

    /// @notice Illustrative band only. Empty at deployment. An issuer may store one. The contract does not
    /// ship a "3 directors at CHF 1m" rule, and that example is not a claim about the PGR.
    struct CapitalBand {
        uint256 capitalAtOrAbove;
        uint8 minDirectors;
    }

    /// @dev Participation of 1 bp of supply. Not a statutory quorum.
    uint16 public constant PLACEHOLDER_ORDINARY_QUORUM_BPS = 1;
    /// @dev Strictly more than half of the for+against votes. Not a statutory majority.
    uint16 public constant PLACEHOLDER_ORDINARY_MAJORITY_BPS = 5000;
    /// @dev Half of supply participating. Not a statutory quorum.
    uint16 public constant PLACEHOLDER_QUALIFIED_QUORUM_BPS = 5000;
    /// @dev Just under two thirds of for+against. Not a statutory majority. 6_666 bps is 66.66 percent.
    uint16 public constant PLACEHOLDER_QUALIFIED_MAJORITY_BPS = 6666;
    uint64 public constant PLACEHOLDER_AGM_NOTICE = 14 days;
    uint64 public constant PLACEHOLDER_EGM_NOTICE = 7 days;
    /// @dev 10 percent of supply. Not a statutory convening right.
    uint16 public constant PLACEHOLDER_MEETING_CALL_BPS = 1000;
    uint64 public constant PLACEHOLDER_CONVENING_REQUEST_TTL = 30 days;
    uint8 public constant PLACEHOLDER_MIN_DIRECTORS = 1;
    /// @dev The owner's requested drag default. Still a placeholder, not a PGR squeeze-out threshold.
    uint16 public constant PLACEHOLDER_DRAG_QUORUM_BPS = 7500;
    /// @dev 30 percent of supply. Not a statutory tag-along trigger.
    uint16 public constant PLACEHOLDER_TAG_THRESHOLD_BPS = 3000;
    uint64 public constant PLACEHOLDER_PREEMPTION_WINDOW = 14 days;
    uint64 public constant PLACEHOLDER_RESPONSE_WINDOW = 30 days;
    uint64 public constant PLACEHOLDER_RECOVERY_DELAY = 30 days;
    /// @dev Software floor so the recovery delay cannot be switched off. Not a statutory waiting period.
    uint64 public constant MIN_RECOVERY_DELAY = 7 days;
    uint16 public constant PLACEHOLDER_RECOVERY_SIGNATURES = 1;
    /// @dev One year. Not a statutory waiting period for unclaimed drag consideration.
    uint64 public constant PLACEHOLDER_UNCLAIMED_WINDOW = 365 days;
    /// @dev Software floor. The owner cannot turn the unclaimed-drag window off. Not a statute.
    uint64 public constant MIN_UNCLAIMED_WINDOW = 180 days;
    /// @dev Software cap, separate from {MAX_PERIOD}, so counsel can store a multi-year wait.
    uint64 public constant MAX_UNCLAIMED_WINDOW = 1825 days;

    /// @dev Software bounds. They stop a nonsense value. They are not statutory minima or maxima.
    uint64 public constant MAX_PERIOD = 366 days;
    uint8 public constant MAX_DIRECTORS_IN_BAND = 50;
    uint256 public constant MAX_BANDS = 16;

    mapping(ResolutionClass => ClassRule) private _classRules;
    mapping(MeetingType => uint64) private _notice;

    uint16 public meetingCallThresholdBps;
    uint64 public conveningRequestTtl;
    uint8 public floorDirectors;
    uint16 public dragQuorumBps;
    uint16 public tagThresholdBps;
    uint64 public preEmptionWindow;
    uint64 public responseWindow;
    uint64 public recoveryDelay;
    uint16 public recoverySignatures;
    /// @notice Default is {BindingMode.Articles}. The governor contract does not read this.
    BindingMode public bindingMode;
    /// @notice Wait after a drag is final before unclaimed consideration can be redirected.
    uint64 public unclaimedWindow;
    /// @notice Where redirected unclaimed drag consideration is credited. Zero disables the redirect.
    address public unclaimedRecipient;

    /// @notice Issuer-declared capital figure in the minor unit the issuer chooses. The contract does not
    /// know the currency and does not check a commercial register.
    uint256 public shareCapital;
    /// @notice Issuer-declared label such as "CHF" or "EUR". A label, not a legal determination.
    bytes32 public currencyCode;

    CapitalBand[] private _bands;

    error BpsOutOfRange(uint16 bps);
    error MajorityUnreachable(uint16 bps);
    error PeriodOutOfRange(uint64 period);
    error DelayBelowFloor(uint64 delay);
    error TooManyBands(uint256 count);
    error InvalidBand(uint8 minDirectors);
    error SignaturesOutOfRange(uint16 count);
    error UnknownClass();
    error InvalidBindingMode(uint8 mode);
    error UnclaimedWindowOutOfRange(uint64 period);

    event ClassRuleSet(ResolutionClass indexed class, uint16 quorumBps, uint16 majorityBps);
    event NoticeSet(MeetingType indexed meetingType, uint64 period);
    event MeetingCallThresholdSet(uint16 bps);
    event ConveningRequestTtlSet(uint64 ttl);
    event FloorDirectorsSet(uint8 minDirectors);
    event CapitalBandsSet(uint256 count);
    event ShareCapitalSet(uint256 shareCapital, bytes32 currencyCode);
    event DragQuorumSet(uint16 bps);
    event TagThresholdSet(uint16 bps);
    event PreEmptionWindowSet(uint64 period);
    event ResponseWindowSet(uint64 period);
    event RecoveryDelaySet(uint64 delay);
    event RecoverySignaturesSet(uint16 count);
    event BindingModeSet(BindingMode mode);
    event UnclaimedWindowSet(uint64 period);
    event UnclaimedRecipientSet(address indexed recipient);
    event PlaceholdersLoaded(address indexed issuer);

    constructor(address issuer) Ownable(issuer) {
        _setClass(ResolutionClass.Ordinary, PLACEHOLDER_ORDINARY_QUORUM_BPS, PLACEHOLDER_ORDINARY_MAJORITY_BPS);
        _setClass(ResolutionClass.Qualified, PLACEHOLDER_QUALIFIED_QUORUM_BPS, PLACEHOLDER_QUALIFIED_MAJORITY_BPS);
        _setNotice(MeetingType.AGM, PLACEHOLDER_AGM_NOTICE);
        _setNotice(MeetingType.EGM, PLACEHOLDER_EGM_NOTICE);
        _setMeetingCall(PLACEHOLDER_MEETING_CALL_BPS);
        _setTtl(PLACEHOLDER_CONVENING_REQUEST_TTL);
        _setFloor(PLACEHOLDER_MIN_DIRECTORS);
        _setDrag(PLACEHOLDER_DRAG_QUORUM_BPS);
        _setTag(PLACEHOLDER_TAG_THRESHOLD_BPS);
        _setPreEmption(PLACEHOLDER_PREEMPTION_WINDOW);
        _setResponse(PLACEHOLDER_RESPONSE_WINDOW);
        _setRecoveryDelay(PLACEHOLDER_RECOVERY_DELAY);
        _setSignatures(PLACEHOLDER_RECOVERY_SIGNATURES);
        _setUnclaimedWindow(PLACEHOLDER_UNCLAIMED_WINDOW);
        currencyCode = "UNSET";
        emit BindingModeSet(BindingMode.Articles);
        emit PlaceholdersLoaded(issuer);
    }

    function classRule(ResolutionClass class) external view returns (ClassRule memory) {
        return _classRules[class];
    }

    function noticePeriod(MeetingType meetingType) external view returns (uint64) {
        return _notice[meetingType];
    }

    function bandCount() external view returns (uint256) {
        return _bands.length;
    }

    function bandAt(uint256 index) external view returns (CapitalBand memory) {
        return _bands[index];
    }

    /// @notice Highest band that the stored capital meets, and at least {floorDirectors}.
    function requiredDirectors() public view returns (uint8 minDirectors) {
        minDirectors = floorDirectors;
        uint256 n = _bands.length;
        for (uint256 i; i < n; ++i) {
            if (shareCapital >= _bands[i].capitalAtOrAbove && _bands[i].minDirectors > minDirectors) {
                minDirectors = _bands[i].minDirectors;
            }
        }
    }

    function setClassRule(ResolutionClass class, uint16 quorumBps, uint16 majorityBps) external onlyOwner {
        _setClass(class, quorumBps, majorityBps);
    }

    function setNoticePeriod(MeetingType meetingType, uint64 period) external onlyOwner {
        _setNotice(meetingType, period);
    }

    function setMeetingCallThreshold(uint16 bps) external onlyOwner {
        _setMeetingCall(bps);
    }

    function setConveningRequestTtl(uint64 ttl) external onlyOwner {
        _setTtl(ttl);
    }

    function setFloorDirectors(uint8 minDirectors) external onlyOwner {
        _setFloor(minDirectors);
    }

    function setCapitalBands(CapitalBand[] calldata bands) external onlyOwner {
        if (bands.length > MAX_BANDS) revert TooManyBands(bands.length);
        delete _bands;
        for (uint256 i; i < bands.length; ++i) {
            if (bands[i].minDirectors == 0 || bands[i].minDirectors > MAX_DIRECTORS_IN_BAND) {
                revert InvalidBand(bands[i].minDirectors);
            }
            _bands.push(bands[i]);
        }
        emit CapitalBandsSet(bands.length);
    }

    function setShareCapital(uint256 capital, bytes32 currency) external onlyOwner {
        shareCapital = capital;
        currencyCode = currency;
        emit ShareCapitalSet(capital, currency);
    }

    function setDragQuorum(uint16 bps) external onlyOwner {
        _setDrag(bps);
    }

    function setTagThreshold(uint16 bps) external onlyOwner {
        _setTag(bps);
    }

    function setPreEmptionWindow(uint64 period) external onlyOwner {
        _setPreEmption(period);
    }

    function setResponseWindow(uint64 period) external onlyOwner {
        _setResponse(period);
    }

    function setRecoveryDelay(uint64 delay) external onlyOwner {
        _setRecoveryDelay(delay);
    }

    function setRecoverySignatures(uint16 count) external onlyOwner {
        _setSignatures(count);
    }

    function setBindingMode(BindingMode mode) external onlyOwner {
        if (uint8(mode) > uint8(BindingMode.Both)) revert InvalidBindingMode(uint8(mode));
        bindingMode = mode;
        emit BindingModeSet(mode);
    }

    function setUnclaimedWindow(uint64 period) external onlyOwner {
        _setUnclaimedWindow(period);
    }

    /// @param recipient Pass zero to disable {GvAcquisition.redirectUnclaimed}. The caller of that
    /// function cannot choose a different address. This owner should be the kit timelock.
    function setUnclaimedRecipient(address recipient) external onlyOwner {
        unclaimedRecipient = recipient;
        emit UnclaimedRecipientSet(recipient);
    }

    /**
     * @notice The articles' outcome for one class. Quorum basis points are the class rule.
     * `bravoQuorum` uses For+Abstain, which is the governor's counting shape, but it uses this class's
     * basis points. It is not a call to the governor's `quorum(timepoint)`, whose numerator is a single
     * percent for every proposal. `bravoMajority` is For strictly greater than Against.
     */
    function canonicalOutcome(
        ResolutionClass class,
        uint256 forVotes,
        uint256 againstVotes,
        uint256 abstainVotes,
        uint256 supply
    ) public view returns (ResolutionOutcome memory outcome) {
        if (uint8(class) > uint8(ResolutionClass.Qualified)) revert UnknownClass();
        ClassRule memory rule = _classRules[class];
        outcome.forVotes = forVotes;
        outcome.againstVotes = againstVotes;
        outcome.abstainVotes = abstainVotes;
        outcome.supply = supply;
        outcome.articlesQuorum = quorumMet(forVotes + againstVotes + abstainVotes, supply, rule.quorumBps);
        outcome.articlesMajority = majorityMet(forVotes, againstVotes, rule.majorityBps);
        outcome.bravoQuorum = quorumMet(forVotes + abstainVotes, supply, rule.quorumBps);
        outcome.bravoMajority = forVotes > againstVotes;
        if (bindingMode == BindingMode.Governor) {
            outcome.passed = outcome.bravoQuorum && outcome.bravoMajority;
        } else if (bindingMode == BindingMode.Both) {
            outcome.passed =
                outcome.articlesQuorum && outcome.articlesMajority && outcome.bravoQuorum && outcome.bravoMajority;
        } else {
            outcome.passed = outcome.articlesQuorum && outcome.articlesMajority;
        }
    }

    /// @notice True when `amount` is at least `bps` of `supply`, rounding the threshold up.
    function meetsShareThreshold(uint256 amount, uint256 supply, uint16 bps) public pure returns (bool) {
        if (supply == 0 || bps == 0) return false;
        return amount >= Math.mulDiv(supply, uint256(bps), 10_000, Math.Rounding.Ceil);
    }

    /// @notice Quorum of participation against supply. A configured quorum of 0 is treated as "no quorum figure".
    function quorumMet(uint256 participation, uint256 supply, uint16 quorumBps) public pure returns (bool) {
        if (quorumBps == 0) return true;
        if (supply == 0) return false;
        return participation >= Math.mulDiv(supply, uint256(quorumBps), 10_000, Math.Rounding.Ceil);
    }

    /// @notice Strictly more than `majorityBps` of the for+against votes. Abstentions are not in this denominator.
    function majorityMet(uint256 forVotes, uint256 againstVotes, uint16 majorityBps) public pure returns (bool) {
        uint256 castVotes = forVotes + againstVotes;
        if (castVotes == 0) return false;
        return forVotes * 10_000 > castVotes * uint256(majorityBps);
    }

    function _setClass(ResolutionClass class, uint16 quorumBps, uint16 majorityBps) private {
        if (uint8(class) > uint8(ResolutionClass.Qualified)) revert UnknownClass();
        if (quorumBps > 10_000) revert BpsOutOfRange(quorumBps);
        // 100 percent cannot be strictly exceeded, so a majority of 10_000 would pass nothing.
        if (majorityBps >= 10_000) revert MajorityUnreachable(majorityBps);
        _classRules[class] = ClassRule({ quorumBps: quorumBps, majorityBps: majorityBps });
        emit ClassRuleSet(class, quorumBps, majorityBps);
    }

    function _setNotice(MeetingType meetingType, uint64 period) private {
        if (uint8(meetingType) > uint8(MeetingType.EGM)) revert UnknownClass();
        if (period == 0 || period > MAX_PERIOD) revert PeriodOutOfRange(period);
        _notice[meetingType] = period;
        emit NoticeSet(meetingType, period);
    }

    function _setMeetingCall(uint16 bps) private {
        if (bps == 0 || bps > 10_000) revert BpsOutOfRange(bps);
        meetingCallThresholdBps = bps;
        emit MeetingCallThresholdSet(bps);
    }

    function _setTtl(uint64 ttl) private {
        if (ttl == 0 || ttl > MAX_PERIOD) revert PeriodOutOfRange(ttl);
        conveningRequestTtl = ttl;
        emit ConveningRequestTtlSet(ttl);
    }

    function _setFloor(uint8 minDirectors) private {
        if (minDirectors == 0 || minDirectors > MAX_DIRECTORS_IN_BAND) revert InvalidBand(minDirectors);
        floorDirectors = minDirectors;
        emit FloorDirectorsSet(minDirectors);
    }

    function _setDrag(uint16 bps) private {
        if (bps == 0 || bps > 10_000) revert BpsOutOfRange(bps);
        dragQuorumBps = bps;
        emit DragQuorumSet(bps);
    }

    function _setTag(uint16 bps) private {
        if (bps == 0 || bps > 10_000) revert BpsOutOfRange(bps);
        tagThresholdBps = bps;
        emit TagThresholdSet(bps);
    }

    function _setPreEmption(uint64 period) private {
        if (period == 0 || period > MAX_PERIOD) revert PeriodOutOfRange(period);
        preEmptionWindow = period;
        emit PreEmptionWindowSet(period);
    }

    function _setResponse(uint64 period) private {
        if (period == 0 || period > MAX_PERIOD) revert PeriodOutOfRange(period);
        responseWindow = period;
        emit ResponseWindowSet(period);
    }

    function _setRecoveryDelay(uint64 delay) private {
        if (delay < MIN_RECOVERY_DELAY || delay > MAX_PERIOD) revert DelayBelowFloor(delay);
        recoveryDelay = delay;
        emit RecoveryDelaySet(delay);
    }

    function _setSignatures(uint16 count) private {
        if (count == 0 || count > MAX_DIRECTORS_IN_BAND) revert SignaturesOutOfRange(count);
        recoverySignatures = count;
        emit RecoverySignaturesSet(count);
    }

    function _setUnclaimedWindow(uint64 period) private {
        if (period < MIN_UNCLAIMED_WINDOW || period > MAX_UNCLAIMED_WINDOW) revert UnclaimedWindowOutOfRange(period);
        unclaimedWindow = period;
        emit UnclaimedWindowSet(period);
    }
}
