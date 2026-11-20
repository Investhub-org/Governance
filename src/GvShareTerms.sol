// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { ECDSA } from "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";
import { EIP712 } from "@openzeppelin/contracts/utils/cryptography/EIP712.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { Math } from "@openzeppelin/contracts/utils/math/Math.sol";
import { GvCompanyRules } from "./GvCompanyRules.sol";
import { GvEscrow } from "./GvEscrow.sol";
import { GvShare } from "./GvShare.sol";
import { IGvSharePolicy, IGvTransferPermit } from "./interfaces/IGvSharePolicy.sol";

/**
 * @title GvShareTerms
 * @notice Issuer-owned SHA binding, whitelist, lock-up, and pre-emption on a {GvShare}.
 * The owner should be the issuer and then the kit timelock. This contract cannot force a transfer of
 * someone else's shares. Forced moves live in {GvAcquisition} and {GvRecovery}, and only after the
 * timelock has bound those contracts as share modules.
 *
 * Holders accept the current SHA version before they can receive shares. The SHA text stays off-chain.
 * The chain stores the keccak256 hash, a version, and an optional CID. Acceptance is stored per account.
 * The holder can call {acceptSha}, a relayer can submit their EIP-712 signature, or anyone can submit a
 * Merkle proof against the root the owner published for this version. The root is the owner's list of
 * accounts that accepted off-chain. The signature is the holder's own proof. Both write `acceptedVersion`.
 *
 * Pre-emption, when enabled, rejects a direct peer transfer. The seller escrows the shares for the
 * window in {GvCompanyRules.preEmptionWindow}. Existing holders may take up to their pro rata cap at
 * the same price. Integer division can leave a remainder of one unit. Balances are read at exercise
 * time, so a transfer during the window changes a cap. A stake at or above the tag-along threshold
 * cannot use this path. It has to be opened as a tag sale.
 *
 * The whitelist is the issuer's transfer list for this token. It is not a copy of a CMTAT rule engine.
 * A wrapped CMTAT keeps that engine on the underlying token.
 *
 * Pre-emption does not apply to a mint or to a transfer from {issuerTreasury}. Those still require the
 * recipient to be whitelisted and to hold the current SHA, and a treasury transfer still respects the
 * sender's lock-up. {PrimaryIssuance} records each one.
 */
contract GvShareTerms is Ownable, GvEscrow, EIP712, IGvSharePolicy {
    uint256 public constant MAX_BATCH = 64;
    bytes32 private constant ACCEPT_TYPEHASH = keccak256("AcceptSha(address account,uint256 version,bytes32 shaHash)");

    struct PreEmption {
        address seller;
        address buyer;
        uint256 amount;
        uint256 pricePerToken;
        address currency;
        uint64 deadline;
        uint256 baseSupply;
        uint256 claimed;
        bool settled;
        bool cancelled;
    }

    GvShare public immutable token;
    GvCompanyRules public immutable rules;

    address public acquisition;
    address public consideration;
    bool public preEmptionEnabled = true;

    /// @notice Primary-issuance wallet. Transfers from this address skip pre-emption and nothing else.
    address public issuerTreasury;

    bytes32 public shaHash;
    uint256 public shaVersion;
    string public shaCid;
    /// @notice Root of leaves `keccak256(bytes.concat(keccak256(abi.encode(account, shaVersion, shaHash))))`.
    /// Cleared when a new SHA version is published. Pairs are sorted. Odd nodes are promoted.
    bytes32 public shaAcceptanceRoot;

    mapping(address account => uint256 version) public acceptedVersion;
    mapping(address account => bool) public whitelisted;
    mapping(address account => uint64 until) public lockedUntil;

    uint256 public preEmptionCount;
    mapping(uint256 id => PreEmption) private _preEmptions;
    mapping(uint256 id => mapping(address holder => uint256 amount)) public exercised;

    address private _gateFrom;
    address private _gateTo;
    uint256 private _gateAmount;

    error NotShare(address caller);
    error ZeroAddress();
    error ConsiderationUnset();
    error WrongCurrency(address currency);
    error ShaNotPublished();
    error MissingHash();
    error CidTooLong();
    error NotWhitelisted(address account);
    error ShaNotAccepted(address account, uint256 version);
    error Locked(address account, uint64 until);
    error PreEmptionRequired();
    error TransferWindowOpen();
    error UseTagAlong();
    error UnknownOffer(uint256 id);
    error OfferClosed(uint256 id);
    error WindowOpen(uint256 id);
    error NotSeller(address caller);
    error CapExceeded(address holder, uint256 cap);
    error NothingRemaining(uint256 id);
    error NoOtherHolders(uint256 id);
    error BuyerCannotExercise(address buyer);
    error BatchBounds(uint256 length, uint256 max);
    error BadSignature(address account);
    error BadProof(address account);
    error AcceptanceRootUnset();

    event ShaPublished(uint256 indexed version, bytes32 shaHash, string cid);
    event ShaAccepted(address indexed account, uint256 indexed version, bytes32 shaHash);
    event ShaAcceptanceRootSet(uint256 indexed version, bytes32 indexed shaHash, bytes32 root);
    event WhitelistSet(address indexed account, bool allowed);
    event IssuerTreasurySet(address indexed treasury);
    /// @notice A mint (`mint` is true, `from` is zero) or a transfer from {issuerTreasury}. Pre-emption did not apply.
    event PrimaryIssuance(address indexed from, address indexed to, uint256 amount, bool mint);
    event LockupSet(address indexed account, uint64 until);
    event PreEmptionEnabledSet(bool enabled);
    event ConsiderationSet(address indexed currency);
    event AcquisitionSet(address indexed acquisition);
    event PreEmptionOffered(
        uint256 indexed id,
        address indexed seller,
        address indexed buyer,
        uint256 amount,
        uint256 pricePerToken,
        uint64 deadline
    );
    event PreEmptionExercised(uint256 indexed id, address indexed holder, uint256 amount, uint256 cost);
    event PreEmptionSettled(uint256 indexed id, address indexed buyer, uint256 amount, uint256 cost);
    event PreEmptionReturned(uint256 indexed id, address indexed seller, uint256 amount);

    constructor(address issuer, GvShare token_, GvCompanyRules rules_, address consideration_)
        Ownable(issuer)
        EIP712("GvShareTerms", "1")
    {
        if (address(token_) == address(0) || address(rules_) == address(0) || consideration_ == address(0)) {
            revert ZeroAddress();
        }
        if (consideration_.code.length == 0) revert ConsiderationUnset();
        token = token_;
        rules = rules_;
        consideration = consideration_;
    }

    function preEmption(uint256 id) external view returns (PreEmption memory) {
        return _preEmptions[id];
    }

    function holdsCurrentSha(address account) public view returns (bool) {
        return shaVersion != 0 && acceptedVersion[account] == shaVersion;
    }

    function publishSha(bytes32 hash, string calldata cid) external onlyOwner returns (uint256 version) {
        if (hash == bytes32(0)) revert MissingHash();
        if (bytes(cid).length > 128) revert CidTooLong();
        version = ++shaVersion;
        shaHash = hash;
        shaCid = cid;
        shaAcceptanceRoot = bytes32(0);
        emit ShaPublished(version, hash, cid);
        emit ShaAcceptanceRootSet(version, hash, bytes32(0));
    }

    function acceptSha() external {
        _recordAcceptance(msg.sender);
    }

    /// @notice EIP-712 digest for the current SHA version. The holder signs this. A relayer submits it.
    function acceptanceDigest(address account) public view returns (bytes32) {
        if (shaVersion == 0) revert ShaNotPublished();
        if (account == address(0)) revert ZeroAddress();
        return _hashTypedDataV4(keccak256(abi.encode(ACCEPT_TYPEHASH, account, shaVersion, shaHash)));
    }

    /// @notice Relay a holder's signature of {acceptanceDigest}. The stored acceptance is still per account.
    function acceptShaBySig(address account, bytes calldata signature) external {
        _acceptBySig(account, signature);
    }

    function acceptShaBySigBatch(address[] calldata accounts, bytes[] calldata signatures) external {
        uint256 n = accounts.length;
        if (n == 0 || n > MAX_BATCH || n != signatures.length) revert BatchBounds(n, MAX_BATCH);
        for (uint256 i; i < n; ++i) {
            _acceptBySig(accounts[i], signatures[i]);
        }
    }

    /// @notice Owner publishes the inclusion root for the current SHA. Publish the SHA first.
    function setShaAcceptanceRoot(bytes32 root) external onlyOwner {
        if (shaVersion == 0) revert ShaNotPublished();
        shaAcceptanceRoot = root;
        emit ShaAcceptanceRootSet(shaVersion, shaHash, root);
    }

    function acceptShaWithProof(address account, bytes32[] calldata proof) external {
        _acceptWithProof(account, proof);
    }

    function acceptShaWithProofBatch(address[] calldata accounts, bytes32[][] calldata proofs) external {
        uint256 n = accounts.length;
        if (n == 0 || n > MAX_BATCH || n != proofs.length) revert BatchBounds(n, MAX_BATCH);
        for (uint256 i; i < n; ++i) {
            _acceptWithProof(accounts[i], proofs[i]);
        }
    }

    function setWhitelist(address account, bool allowed) external onlyOwner {
        _setWhitelist(account, allowed);
    }

    function setWhitelistBatch(address[] calldata accounts, bool allowed) external onlyOwner {
        uint256 n = accounts.length;
        if (n == 0 || n > MAX_BATCH) revert BatchBounds(n, MAX_BATCH);
        for (uint256 i; i < n; ++i) {
            _setWhitelist(accounts[i], allowed);
        }
    }

    function setIssuerTreasury(address treasury) external onlyOwner {
        issuerTreasury = treasury;
        emit IssuerTreasurySet(treasury);
    }

    function setLockup(address account, uint64 until) external onlyOwner {
        if (account == address(0)) revert ZeroAddress();
        lockedUntil[account] = until;
        emit LockupSet(account, until);
    }

    function setPreEmptionEnabled(bool enabled) external onlyOwner {
        preEmptionEnabled = enabled;
        emit PreEmptionEnabledSet(enabled);
    }

    function setConsideration(address currency) external onlyOwner {
        if (currency == address(0) || currency.code.length == 0) revert ConsiderationUnset();
        consideration = currency;
        emit ConsiderationSet(currency);
    }

    function setAcquisition(address acquisition_) external onlyOwner {
        if (acquisition_ == address(0)) revert ZeroAddress();
        acquisition = acquisition_;
        emit AcquisitionSet(acquisition_);
    }

    /**
     * @notice Called by the share token. A transfer this contract just armed, or one the acquisition
     * contract just armed, is allowed through. Every other peer transfer must pass the whitelist,
     * the recipient's SHA acceptance, the lock-up, and pre-emption.
     */
    function authorizeTransfer(address from, address to, uint256 amount) external {
        if (msg.sender != address(token)) revert NotShare(msg.sender);
        if (from == _gateFrom && to == _gateTo && amount == _gateAmount && amount != 0) return;
        if (acquisition != address(0) && IGvTransferPermit(acquisition).permitsTransfer(from, to, amount)) return;
        if (acquisition != address(0) && IGvTransferPermit(acquisition).blocksPeerTransfers()) {
            revert TransferWindowOpen();
        }
        if (to == address(0)) revert PreEmptionRequired();

        bool mint = from == address(0);
        bool treasury = issuerTreasury != address(0) && from == issuerTreasury;
        if (!mint) {
            if (lockedUntil[from] > block.timestamp) revert Locked(from, lockedUntil[from]);
            if (!whitelisted[from]) revert NotWhitelisted(from);
            if (treasury && !holdsCurrentSha(from)) revert ShaNotAccepted(from, shaVersion);
        }
        _checkRecipient(to);
        if (mint || treasury) {
            emit PrimaryIssuance(from, to, amount, mint);
            return;
        }
        if (preEmptionEnabled) revert PreEmptionRequired();
    }

    function startPreEmption(address buyer, uint256 amount, uint256 pricePerToken) external returns (uint256 id) {
        if (buyer == address(0) || buyer == msg.sender) revert ZeroAddress();
        if (amount == 0) revert ZeroValue();
        if (consideration == address(0)) revert ConsiderationUnset();
        if (lockedUntil[msg.sender] > block.timestamp) revert Locked(msg.sender, lockedUntil[msg.sender]);
        if (!whitelisted[msg.sender]) revert NotWhitelisted(msg.sender);
        _checkRecipient(buyer);
        _blockIfSaleOpen();
        uint256 supply = token.totalSupply();
        if (rules.meetsShareThreshold(amount, supply, rules.tagThresholdBps())) revert UseTagAlong();

        uint256 sellerBefore = token.balanceOf(msg.sender);
        if (sellerBefore < amount) revert NothingRemaining(0);
        _gated(msg.sender, address(this), amount);
        // Other holders, measured before the escrow move. The seller's remaining shares are not in the base.
        uint256 baseSupply = supply - sellerBefore;
        id = ++preEmptionCount;
        PreEmption storage offer = _preEmptions[id];
        offer.seller = msg.sender;
        offer.buyer = buyer;
        offer.amount = amount;
        offer.pricePerToken = pricePerToken;
        offer.currency = consideration;
        offer.deadline = uint64(block.timestamp) + rules.preEmptionWindow();
        offer.baseSupply = baseSupply;
        emit PreEmptionOffered(id, msg.sender, buyer, amount, pricePerToken, offer.deadline);
    }

    function exercisePreEmption(uint256 id, uint256 amount) external nonReentrant {
        PreEmption storage offer = _preEmptions[id];
        if (offer.seller == address(0)) revert UnknownOffer(id);
        if (offer.settled || offer.cancelled) revert OfferClosed(id);
        if (block.timestamp > offer.deadline) revert OfferClosed(id);
        if (amount == 0) revert ZeroValue();
        if (msg.sender == offer.seller || msg.sender == offer.buyer) revert BuyerCannotExercise(msg.sender);
        if (offer.baseSupply == 0) revert NoOtherHolders(id);
        uint256 already = exercised[id][msg.sender];
        uint256 held = token.balanceOf(msg.sender) + already;
        uint256 cap = Math.mulDiv(offer.amount, held, offer.baseSupply);
        if (already + amount > cap) revert CapExceeded(msg.sender, cap);
        if (offer.claimed + amount > offer.amount) revert NothingRemaining(id);
        _checkRecipient(msg.sender);

        uint256 cost = Math.mulDiv(amount, offer.pricePerToken, 1);
        if (cost > 0) _pull(offer.currency, msg.sender, cost);
        offer.claimed += amount;
        exercised[id][msg.sender] = already + amount;
        _gated(address(this), msg.sender, amount);
        if (cost > 0) _credit(offer.seller, offer.currency, cost);
        emit PreEmptionExercised(id, msg.sender, amount, cost);
    }

    function settlePreEmption(uint256 id) external nonReentrant {
        PreEmption storage offer = _preEmptions[id];
        if (offer.seller == address(0) || offer.settled || offer.cancelled) revert OfferClosed(id);
        if (block.timestamp <= offer.deadline) revert WindowOpen(id);
        uint256 remaining = offer.amount - offer.claimed;
        if (remaining == 0) revert NothingRemaining(id);
        _checkRecipient(offer.buyer);
        uint256 cost = Math.mulDiv(remaining, offer.pricePerToken, 1);
        if (cost > 0) _pull(offer.currency, offer.buyer, cost);
        offer.settled = true;
        _gated(address(this), offer.buyer, remaining);
        if (cost > 0) _credit(offer.seller, offer.currency, cost);
        emit PreEmptionSettled(id, offer.buyer, remaining, cost);
    }

    function returnUnsold(uint256 id) external nonReentrant {
        PreEmption storage offer = _preEmptions[id];
        if (offer.seller == address(0) || offer.settled || offer.cancelled) revert OfferClosed(id);
        if (block.timestamp <= offer.deadline) revert WindowOpen(id);
        if (msg.sender != offer.seller) revert NotSeller(msg.sender);
        uint256 remaining = offer.amount - offer.claimed;
        if (remaining == 0) revert NothingRemaining(id);
        offer.cancelled = true;
        _gated(address(this), offer.seller, remaining);
        emit PreEmptionReturned(id, offer.seller, remaining);
    }

    function _setWhitelist(address account, bool allowed) private {
        if (account == address(0)) revert ZeroAddress();
        whitelisted[account] = allowed;
        emit WhitelistSet(account, allowed);
    }

    function _recordAcceptance(address account) private {
        if (shaVersion == 0) revert ShaNotPublished();
        if (account == address(0)) revert ZeroAddress();
        acceptedVersion[account] = shaVersion;
        emit ShaAccepted(account, shaVersion, shaHash);
    }

    function _acceptBySig(address account, bytes calldata signature) private {
        address signer = ECDSA.recover(acceptanceDigest(account), signature);
        if (signer != account) revert BadSignature(account);
        _recordAcceptance(account);
    }

    function _acceptWithProof(address account, bytes32[] calldata proof) private {
        if (shaVersion == 0) revert ShaNotPublished();
        if (shaAcceptanceRoot == bytes32(0)) revert AcceptanceRootUnset();
        if (account == address(0)) revert ZeroAddress();
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(account, shaVersion, shaHash))));
        if (!MerkleProof.verifyCalldata(proof, shaAcceptanceRoot, leaf)) revert BadProof(account);
        _recordAcceptance(account);
    }

    function _checkRecipient(address account) private view {
        if (!whitelisted[account]) revert NotWhitelisted(account);
        if (!holdsCurrentSha(account)) revert ShaNotAccepted(account, shaVersion);
    }

    function _blockIfSaleOpen() private view {
        if (acquisition != address(0) && IGvTransferPermit(acquisition).blocksPeerTransfers()) {
            revert TransferWindowOpen();
        }
    }

    function _gated(address from, address to, uint256 amount) private {
        _gateFrom = from;
        _gateTo = to;
        _gateAmount = amount;
        if (from == address(this)) token.transfer(to, amount);
        else token.transferFrom(from, to, amount);
        _gateFrom = address(0);
        _gateTo = address(0);
        _gateAmount = 0;
    }
}
