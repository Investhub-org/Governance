// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { GvCompanyRules } from "./GvCompanyRules.sol";
import { GvEscrow } from "./GvEscrow.sol";
import { GvShare } from "./GvShare.sol";
import { GvShareTerms } from "./GvShareTerms.sol";
import { IGvShareModule, IGvTransferPermit } from "./interfaces/IGvSharePolicy.sol";

/**
 * @title GvAcquisition
 * @notice Drag-along and tag-along for one share token.
 *
 * Design reference, not a copy: Aktionariat's public notes on an acquisition offer (one price per
 * share, every holder exits on that price, proceeds are claimable, nobody has a silent transfer key).
 * Their DragAlong.sol is Business Source License 1.1 and was not copied. Their older DraggableShares
 * are under a fee-preserving licence and were not copied either. See docs/legal-wrapper.md.
 * The trigger here is the one this kit was asked to enforce: an acceptance quorum with the
 * consideration escrowed up front, not a veto and not a wrapper-base swap.
 *
 * Drag-along. A buyer escrows the consideration token for `pricePerToken * totalSupply`. Holders
 * accept by escrowing shares. The buyer's own holding counts as well, capped by the balance recorded
 * at {postDrag} and by the live balance, so a later acquisition cannot inflate it and a later loss
 * cannot keep counting shares the buyer no longer holds. The buyer cannot tender on top of that.
 * If the sum reaches the offer quorum before the deadline, anyone may execute. The offer is then
 * final and transfers of this token stay frozen. Each holder, or anyone on their behalf, pulls
 * their consideration from escrow. {pushDrag} is a bounded push for a small cap table. After
 * {GvCompanyRules.unclaimedWindow}, unclaimed consideration can be credited to the recipient the
 * rules name, not to an address the caller chooses. There is no admin function that chooses an
 * arbitrary share recipient. The shares always move to the stored buyer.
 *
 * Tag-along. A sale at or above the configured fraction of supply cannot settle on the pre-emption
 * path. The buyer escrows the price of the seller's stake plus the pro rata capacity of every other
 * holder. Pro rata means the same fraction of each other holding that the seller is selling of their
 * own holding, at the same price per share. The sale settles only after the window, whether or not
 * anyone joined.
 *
 * The quorum and the threshold are read from {GvCompanyRules}. The 75 percent drag default and the
 * 30 percent tag default are placeholders. They are not a statement of the PGR.
 *
 * This contract has no owner. Wiring it as a share module is a timelock call on the token.
 */
contract GvAcquisition is GvEscrow, IGvShareModule, IGvTransferPermit {
    struct Drag {
        address buyer;
        address currency;
        uint256 pricePerToken;
        uint64 deadline;
        uint16 quorumBps;
        uint256 supplyAtPost;
        uint256 buyerHeldAtPost;
        uint256 escrowed;
        uint256 acceptedShares;
        uint256 paidOut;
        uint64 quorumReachedAt;
        uint64 executedAt;
        bool executed;
        bool cancelled;
        bool surplusRefunded;
    }

    struct Tag {
        address seller;
        address buyer;
        address currency;
        uint256 stake;
        uint256 sellerBalanceAtOpen;
        uint256 pricePerToken;
        uint64 deadline;
        uint256 escrowed;
        uint256 maxJoin;
        uint256 joinedShares;
        bool settled;
        bool cancelled;
    }

    /// @notice Upper bound on one {pushDrag} or {redirectUnclaimedBatch} call. A small cap table, not 5,000.
    uint256 public constant MAX_PUSH = 32;

    GvShare public immutable token;
    GvCompanyRules public immutable rules;
    GvShareTerms public immutable terms;

    uint256 public dragCount;
    uint256 public activeDrag;
    mapping(uint256 id => Drag) private _drags;
    mapping(uint256 id => mapping(address holder => uint256 amount)) public acceptedAmount;

    uint256 public tagCount;
    uint256 public activeTag;
    mapping(uint256 id => Tag) private _tags;
    mapping(uint256 id => mapping(address holder => uint256 amount)) public joinedAmount;

    address private _allowFrom;
    address private _allowTo;
    uint256 private _allowAmount;
    address private _forceFrom;
    address private _forceTo;
    uint256 private _forceAmount;

    error ZeroAddress();
    error UnknownOffer(uint256 id);
    error OfferClosed(uint256 id);
    error OfferPending();
    error WindowClosed(uint256 id);
    error TooEarly(uint256 id, uint64 deadline);
    error QuorumNotConfigured(uint16 offered, uint16 minimum);
    error SupplyChanged(uint256 snapshot, uint256 current);
    error QuorumNotReached(uint256 acceptedShares, uint256 required);
    error QuorumAlreadyReached(uint256 id);
    error NotBuyer(address caller);
    error NotParty(address caller);
    error BuyerCannotAccept(address buyer);
    error BelowTagThreshold(uint256 stake, uint256 supply);
    error AboveSellerBalance(uint256 stake, uint256 balance);
    error CapExceeded(address holder, uint256 cap);
    error NothingToConvert(address holder);
    error NotExecuted(uint256 id);
    error BatchBounds(uint256 length, uint256 max);
    error UnclaimedRecipientUnset();
    error SharesOutstanding(uint256 id);
    error JoinsAlreadyMade(uint256 id);
    error SellerFraction(uint256 sellerBalance);

    event DragOfferPosted(
        uint256 indexed id,
        address indexed buyer,
        address currency,
        uint256 pricePerToken,
        uint256 escrowed,
        uint64 deadline,
        uint16 quorumBps
    );
    event DragAccepted(uint256 indexed id, address indexed holder, uint256 amount, uint256 acceptedShares);
    event DragExecuted(uint256 indexed id, uint256 counted, uint256 buyerCounted, uint64 reachedAt);
    event DragClaimed(
        uint256 indexed id, address indexed holder, address indexed creditor, uint256 amount, uint256 cost
    );
    event DragUnclaimedRedirected(
        uint256 indexed id, address indexed holder, address indexed recipient, uint256 amount, uint256 cost
    );
    event DragCancelled(uint256 indexed id);
    event TagSaleOpened(
        uint256 indexed id,
        address indexed seller,
        address indexed buyer,
        uint256 stake,
        uint256 pricePerToken,
        uint256 maxJoin,
        uint64 deadline
    );
    event TagJoined(uint256 indexed id, address indexed holder, uint256 amount);
    event TagSettled(uint256 indexed id, uint256 sellerStake, uint256 joinedShares);
    event TagClaimed(uint256 indexed id, address indexed holder, uint256 amount, uint256 cost);
    event TagCancelled(uint256 indexed id);

    constructor(GvShare token_, GvCompanyRules rules_, GvShareTerms terms_) {
        if (address(token_) == address(0) || address(rules_) == address(0) || address(terms_) == address(0)) {
            revert ZeroAddress();
        }
        if (address(terms_.token()) != address(token_)) revert ZeroAddress();
        token = token_;
        rules = rules_;
        terms = terms_;
    }

    function drag(uint256 id) external view returns (Drag memory) {
        return _drags[id];
    }

    function tag(uint256 id) external view returns (Tag memory) {
        return _tags[id];
    }

    function permitsTransfer(address from, address to, uint256 amount) external view returns (bool) {
        return from == _allowFrom && to == _allowTo && amount == _allowAmount && amount != 0;
    }

    /// @notice Accepted shares plus the buyer's counted holding, and the quorum those must reach.
    function dragQuorumProgress(uint256 id)
        external
        view
        returns (uint256 counted, uint256 requiredShares, uint256 buyerCounted_)
    {
        Drag storage offer = _drags[id];
        buyerCounted_ = _buyerCounted(offer);
        counted = offer.acceptedShares + buyerCounted_;
        requiredShares = _required(offer);
    }

    function mayForceTransfer(address from, address to, uint256 amount) external view returns (bool) {
        return from == _forceFrom && to == _forceTo && amount == _forceAmount && amount != 0;
    }

    function blocksPeerTransfers() external view returns (bool) {
        if (_tagOpen()) return true;
        uint256 id = activeDrag;
        if (id == 0) return false;
        Drag storage offer = _drags[id];
        if (offer.cancelled) return false;
        if (!offer.executed) return true;
        return token.balanceOf(offer.buyer) != token.totalSupply() || token.balanceOf(address(this)) != 0;
    }

    function postDrag(uint256 pricePerToken, uint64 deadline, uint16 quorumBps)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (_liveDrag() || _tagOpen()) revert OfferPending();
        if (pricePerToken == 0) revert ZeroValue();
        if (deadline <= block.timestamp) revert WindowClosed(0);
        uint16 minimum = rules.dragQuorumBps();
        if (quorumBps < minimum || quorumBps > 10_000) revert QuorumNotConfigured(quorumBps, minimum);
        address currency = terms.consideration();
        uint256 supply = token.totalSupply();
        if (supply == 0) revert ZeroValue();
        uint256 escrowed = Math.mulDiv(pricePerToken, supply, 1);
        _pull(currency, msg.sender, escrowed);

        id = ++dragCount;
        activeDrag = id;
        Drag storage offer = _drags[id];
        offer.buyer = msg.sender;
        offer.currency = currency;
        offer.pricePerToken = pricePerToken;
        offer.deadline = deadline;
        offer.quorumBps = quorumBps;
        offer.supplyAtPost = supply;
        offer.buyerHeldAtPost = token.balanceOf(msg.sender);
        offer.escrowed = escrowed;
        if (_quorumReached(offer)) offer.quorumReachedAt = uint64(block.timestamp);
        emit DragOfferPosted(id, msg.sender, currency, pricePerToken, escrowed, deadline, quorumBps);
    }

    function acceptDrag(uint256 id, uint256 amount) external nonReentrant {
        Drag storage offer = _drags[id];
        if (offer.buyer == address(0) || offer.executed || offer.cancelled) revert OfferClosed(id);
        if (block.timestamp > offer.deadline) revert WindowClosed(id);
        if (msg.sender == offer.buyer) revert BuyerCannotAccept(msg.sender);
        if (amount == 0) revert ZeroValue();
        _permittedFrom(msg.sender, address(this), amount);
        offer.acceptedShares += amount;
        acceptedAmount[id][msg.sender] += amount;
        if (offer.quorumReachedAt == 0 && _quorumReached(offer)) offer.quorumReachedAt = uint64(block.timestamp);
        emit DragAccepted(id, msg.sender, amount, offer.acceptedShares);
    }

    function executeDrag(uint256 id) external {
        Drag storage offer = _drags[id];
        if (offer.buyer == address(0) || offer.executed || offer.cancelled) revert OfferClosed(id);
        if (offer.quorumReachedAt == 0 || offer.quorumReachedAt > offer.deadline || !_quorumReached(offer)) {
            revert QuorumNotReached(offer.acceptedShares + _buyerCounted(offer), _required(offer));
        }
        if (token.totalSupply() != offer.supplyAtPost) revert SupplyChanged(offer.supplyAtPost, token.totalSupply());
        if (!terms.whitelisted(offer.buyer) || !terms.holdsCurrentSha(offer.buyer)) revert NotBuyer(offer.buyer);
        offer.executed = true;
        offer.executedAt = uint64(block.timestamp);
        emit DragExecuted(id, offer.acceptedShares + _buyerCounted(offer), _buyerCounted(offer), offer.quorumReachedAt);
    }

    /// @notice Pull one holder's consideration. Anyone may call. The currency is credited to `holder`.
    /// Escrowed tenders and the free balance both move to the stored buyer, at the offer price.
    function claimDrag(uint256 id, address holder) external nonReentrant {
        Drag storage offer = _drags[id];
        if (!offer.executed || offer.cancelled) revert NotExecuted(id);
        (uint256 amount, uint256 cost) = _settle(offer, id, holder, holder);
        emit DragClaimed(id, holder, holder, amount, cost);
    }

    /// @notice Bounded push for a small cap table. Same settlement as {claimDrag}. Empty holders are skipped.
    function pushDrag(uint256 id, address[] calldata holders) external nonReentrant returns (uint256 settled) {
        if (holders.length == 0 || holders.length > MAX_PUSH) revert BatchBounds(holders.length, MAX_PUSH);
        Drag storage offer = _drags[id];
        if (!offer.executed || offer.cancelled) revert NotExecuted(id);
        for (uint256 i; i < holders.length; ++i) {
            if (!_hasClaim(offer, id, holders[i])) continue;
            (uint256 amount, uint256 cost) = _settle(offer, id, holders[i], holders[i]);
            emit DragClaimed(id, holders[i], holders[i], amount, cost);
            settled += 1;
        }
        if (settled == 0) revert NothingToConvert(address(0));
    }

    /**
     * @notice After the rules' unclaimed window, credit one holder's consideration to {GvCompanyRules.unclaimedRecipient}
     * and move the shares to the buyer. The caller does not choose the recipient. The holder can still
     * {claimDrag} through the window, including the deadline second.
     */
    function redirectUnclaimed(uint256 id, address holder) external nonReentrant {
        Drag storage offer = _drags[id];
        if (!offer.executed || offer.cancelled) revert NotExecuted(id);
        address recipient = _unclaimedReady(offer, id);
        (uint256 amount, uint256 cost) = _settle(offer, id, holder, recipient);
        emit DragUnclaimedRedirected(id, holder, recipient, amount, cost);
    }

    /// @notice Bounded form of {redirectUnclaimed}.
    function redirectUnclaimedBatch(uint256 id, address[] calldata holders)
        external
        nonReentrant
        returns (uint256 settled)
    {
        if (holders.length == 0 || holders.length > MAX_PUSH) revert BatchBounds(holders.length, MAX_PUSH);
        Drag storage offer = _drags[id];
        if (!offer.executed || offer.cancelled) revert NotExecuted(id);
        address recipient = _unclaimedReady(offer, id);
        for (uint256 i; i < holders.length; ++i) {
            if (!_hasClaim(offer, id, holders[i])) continue;
            (uint256 amount, uint256 cost) = _settle(offer, id, holders[i], recipient);
            emit DragUnclaimedRedirected(id, holders[i], recipient, amount, cost);
            settled += 1;
        }
        if (settled == 0) revert NothingToConvert(address(0));
    }

    function cancelDrag(uint256 id) external nonReentrant {
        Drag storage offer = _drags[id];
        if (offer.buyer == address(0) || offer.executed || offer.cancelled) revert OfferClosed(id);
        if (_quorumReached(offer)) revert QuorumAlreadyReached(id);
        if (msg.sender != offer.buyer && block.timestamp <= offer.deadline) revert NotBuyer(msg.sender);
        offer.cancelled = true;
        if (activeDrag == id) activeDrag = 0;
        _credit(offer.buyer, offer.currency, offer.escrowed);
        emit DragCancelled(id);
    }

    function reclaimDrag(uint256 id) external nonReentrant {
        Drag storage offer = _drags[id];
        if (!offer.cancelled) revert OfferClosed(id);
        uint256 amount = acceptedAmount[id][msg.sender];
        if (amount == 0) revert NothingToConvert(msg.sender);
        acceptedAmount[id][msg.sender] = 0;
        offer.acceptedShares -= amount;
        _permittedSend(msg.sender, amount);
    }

    function refundDragSurplus(uint256 id) external nonReentrant {
        Drag storage offer = _drags[id];
        if (!offer.executed || offer.surplusRefunded) revert OfferClosed(id);
        if (token.balanceOf(offer.buyer) != token.totalSupply() || token.balanceOf(address(this)) != 0) {
            revert SharesOutstanding(id);
        }
        offer.surplusRefunded = true;
        if (activeDrag == id) activeDrag = 0;
        uint256 surplus = offer.escrowed - offer.paidOut;
        if (surplus > 0) _credit(offer.buyer, offer.currency, surplus);
    }

    function openTagSale(address buyer, uint256 stake, uint256 pricePerToken, uint64 deadline)
        external
        nonReentrant
        returns (uint256 id)
    {
        if (_liveDrag() || _tagOpen()) revert OfferPending();
        if (buyer == address(0) || buyer == msg.sender) revert ZeroAddress();
        if (stake == 0 || pricePerToken == 0) revert ZeroValue();
        if (deadline <= block.timestamp) revert WindowClosed(0);
        uint256 sellerBalance = token.balanceOf(msg.sender);
        if (stake > sellerBalance) revert AboveSellerBalance(stake, sellerBalance);
        if (sellerBalance == 0) revert SellerFraction(0);
        uint256 supply = token.totalSupply();
        if (!rules.meetsShareThreshold(stake, supply, rules.tagThresholdBps())) {
            revert BelowTagThreshold(stake, supply);
        }
        if (!terms.whitelisted(buyer) || !terms.holdsCurrentSha(buyer)) revert NotBuyer(buyer);
        uint256 others = supply - sellerBalance;
        uint256 maxJoin = Math.mulDiv(others, stake, sellerBalance);
        address currency = terms.consideration();
        uint256 escrowed = Math.mulDiv(pricePerToken, stake + maxJoin, 1);
        _pull(currency, buyer, escrowed);
        _permittedFrom(msg.sender, address(this), stake);

        id = ++tagCount;
        activeTag = id;
        Tag storage sale = _tags[id];
        sale.seller = msg.sender;
        sale.buyer = buyer;
        sale.currency = currency;
        sale.stake = stake;
        sale.sellerBalanceAtOpen = sellerBalance;
        sale.pricePerToken = pricePerToken;
        sale.deadline = deadline;
        sale.escrowed = escrowed;
        sale.maxJoin = maxJoin;
        emit TagSaleOpened(id, msg.sender, buyer, stake, pricePerToken, maxJoin, deadline);
    }

    function joinTag(uint256 id, uint256 amount) external nonReentrant {
        Tag storage sale = _tags[id];
        if (sale.seller == address(0) || sale.settled || sale.cancelled) revert OfferClosed(id);
        if (block.timestamp > sale.deadline) revert WindowClosed(id);
        if (msg.sender == sale.seller || msg.sender == sale.buyer) revert NotParty(msg.sender);
        if (amount == 0) revert ZeroValue();
        uint256 already = joinedAmount[id][msg.sender];
        uint256 cap = Math.mulDiv(token.balanceOf(msg.sender) + already, sale.stake, sale.sellerBalanceAtOpen);
        if (already + amount > cap) revert CapExceeded(msg.sender, cap);
        if (sale.joinedShares + amount > sale.maxJoin) revert CapExceeded(msg.sender, sale.maxJoin);
        if (!terms.whitelisted(msg.sender) || !terms.holdsCurrentSha(msg.sender)) revert NotParty(msg.sender);
        _permittedFrom(msg.sender, address(this), amount);
        joinedAmount[id][msg.sender] = already + amount;
        sale.joinedShares += amount;
        emit TagJoined(id, msg.sender, amount);
    }

    function settleTag(uint256 id) external nonReentrant {
        Tag storage sale = _tags[id];
        if (sale.seller == address(0) || sale.settled || sale.cancelled) revert OfferClosed(id);
        if (block.timestamp <= sale.deadline) revert TooEarly(id, sale.deadline);
        sale.settled = true;
        if (activeTag == id) activeTag = 0;
        _permittedSend(sale.buyer, sale.stake);
        uint256 sellerCost = Math.mulDiv(sale.stake, sale.pricePerToken, 1);
        uint256 joinedCost = Math.mulDiv(sale.joinedShares, sale.pricePerToken, 1);
        _credit(sale.seller, sale.currency, sellerCost);
        uint256 refund = sale.escrowed - sellerCost - joinedCost;
        if (refund > 0) _credit(sale.buyer, sale.currency, refund);
        emit TagSettled(id, sale.stake, sale.joinedShares);
    }

    function claimTag(uint256 id) external nonReentrant {
        Tag storage sale = _tags[id];
        if (!sale.settled) revert NotExecuted(id);
        uint256 amount = joinedAmount[id][msg.sender];
        if (amount == 0) revert NothingToConvert(msg.sender);
        joinedAmount[id][msg.sender] = 0;
        uint256 cost = Math.mulDiv(amount, sale.pricePerToken, 1);
        _permittedSend(sale.buyer, amount);
        _credit(msg.sender, sale.currency, cost);
        emit TagClaimed(id, msg.sender, amount, cost);
    }

    function cancelTag(uint256 id) external nonReentrant {
        Tag storage sale = _tags[id];
        if (sale.seller == address(0) || sale.settled || sale.cancelled) revert OfferClosed(id);
        if (sale.joinedShares != 0) revert JoinsAlreadyMade(id);
        if (msg.sender != sale.seller && msg.sender != sale.buyer) revert NotParty(msg.sender);
        sale.cancelled = true;
        if (activeTag == id) activeTag = 0;
        _permittedSend(sale.seller, sale.stake);
        _credit(sale.buyer, sale.currency, sale.escrowed);
        emit TagCancelled(id);
    }

    function _unclaimedReady(Drag storage offer, uint256 id) private view returns (address recipient) {
        recipient = rules.unclaimedRecipient();
        if (recipient == address(0)) revert UnclaimedRecipientUnset();
        uint64 end = offer.executedAt + rules.unclaimedWindow();
        if (block.timestamp <= end) revert TooEarly(id, end);
    }

    /// @dev Snapshot at posting, capped by the live balance. Shares gained later do not count.
    /// Shares the buyer no longer holds do not count. The buyer cannot also be in `acceptedShares`.
    function _buyerCounted(Drag storage offer) private view returns (uint256) {
        if (offer.buyer == address(0)) return 0;
        uint256 live = token.balanceOf(offer.buyer);
        return live < offer.buyerHeldAtPost ? live : offer.buyerHeldAtPost;
    }

    function _hasClaim(Drag storage offer, uint256 id, address holder) private view returns (bool) {
        if (holder == address(0) || holder == offer.buyer || holder == address(this)) return false;
        return acceptedAmount[id][holder] != 0 || token.balanceOf(holder) != 0;
    }

    function _settle(Drag storage offer, uint256 id, address holder, address creditor)
        private
        returns (uint256 amount, uint256 cost)
    {
        if (!_hasClaim(offer, id, holder)) revert NothingToConvert(holder);
        uint256 escrowed = acceptedAmount[id][holder];
        uint256 freeBalance = token.balanceOf(holder);
        if (escrowed > 0) {
            acceptedAmount[id][holder] = 0;
            offer.acceptedShares -= escrowed;
            cost = _pay(offer, address(this), creditor, escrowed);
            amount = escrowed;
        }
        if (freeBalance > 0) {
            cost += _pay(offer, holder, creditor, freeBalance);
            amount += freeBalance;
        }
    }

    function _pay(Drag storage offer, address from, address creditor, uint256 amount) private returns (uint256 cost) {
        cost = Math.mulDiv(amount, offer.pricePerToken, 1);
        if (offer.paidOut + cost > offer.escrowed) revert EscrowShortfall(offer.currency);
        offer.paidOut += cost;
        _credit(creditor, offer.currency, cost);
        _force(from, offer.buyer, amount);
    }

    function _quorumReached(Drag storage offer) private view returns (bool) {
        return offer.acceptedShares + _buyerCounted(offer) >= _required(offer);
    }

    function _required(Drag storage offer) private view returns (uint256) {
        return Math.mulDiv(offer.supplyAtPost, uint256(offer.quorumBps), 10_000, Math.Rounding.Ceil);
    }

    function _liveDrag() private view returns (bool) {
        uint256 id = activeDrag;
        if (id == 0) return false;
        Drag storage offer = _drags[id];
        return !offer.cancelled && !offer.executed;
    }

    function _tagOpen() private view returns (bool) {
        uint256 id = activeTag;
        if (id == 0) return false;
        Tag storage sale = _tags[id];
        return !sale.cancelled && !sale.settled;
    }

    function _permittedFrom(address from, address to, uint256 amount) private {
        _arm(from, to, amount);
        token.transferFrom(from, to, amount);
        _clearAllow();
    }

    function _permittedSend(address to, uint256 amount) private {
        _arm(address(this), to, amount);
        token.transfer(to, amount);
        _clearAllow();
    }

    function _arm(address from, address to, uint256 amount) private {
        _allowFrom = from;
        _allowTo = to;
        _allowAmount = amount;
    }

    function _clearAllow() private {
        _allowFrom = address(0);
        _allowTo = address(0);
        _allowAmount = 0;
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
