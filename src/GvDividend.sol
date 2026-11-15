// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { MerkleProof } from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
 * @title GvDividend
 * @notice Epoch merkle distributor for an ERC-20 dividend token (USDC, or any non-rebasing ERC-20
 * that does not take a fee). One epoch is one distribution. Paying 5,000 holders does not loop
 * on-chain: the issuer builds a tree off-chain, and a proposal stores only the root.
 *
 * Leaf (OpenZeppelin StandardMerkleTree style, double hashed, sorted pairs):
 *
 * `keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))))`
 *
 * Internal nodes are `keccak256(left || right)` with the pair sorted. An odd node is promoted.
 * `index` must be unique inside an epoch. The bitmap key is the index, so a second leaf with the
 * same index can never be paid.
 *
 * Only the kit timelock can start an epoch or sweep unclaimed tokens after the deadline.
 * Anyone can fund an epoch, up to `totalAllocation`, and anyone can submit a claim. The tokens
 * are transferred to the leaf account, not to `msg.sender`. Claims stay closed until the epoch
 * is fully funded, so a partial deposit cannot be raced.
 *
 * The contract does not read balances and does not know the legal register. A root that a vote
 * approves is paid as written. Build the tree from share balances, not from delegated votes,
 * unless the issuer's own rules say otherwise.
 */
contract GvDividend is ReentrancyGuard {
    using SafeERC20 for IERC20;

    address public immutable timelock;

    struct Distribution {
        address token;
        bytes32 merkleRoot;
        uint256 totalAllocation;
        uint256 funded;
        uint256 claimed;
        uint64 deadline;
        bool swept;
        string metadataURI;
    }

    mapping(uint256 epoch => Distribution) private _distributions;
    /// @dev epoch => bitmap word => bits. Word is `index / 256`.
    mapping(uint256 epoch => mapping(uint256 word => uint256 bits)) private _claimed;
    mapping(address token => uint256 amount) public reserved;

    uint256 public distributionCount;

    error OnlyTimelock(address caller);
    error ZeroAddress();
    error ZeroValue();
    error UnknownEpoch(uint256 epoch);
    error AlreadyClaimed(uint256 epoch, uint256 index);
    error AlreadySwept(uint256 epoch);
    error DeadlinePassed(uint256 epoch);
    error DeadlineNotReached(uint256 epoch);
    error NotFullyFunded(uint256 epoch);
    error Overfund(uint256 epoch, uint256 attempted, uint256 totalAllocation);
    error AllocationExceeded(uint256 epoch);
    error InvalidProof(uint256 epoch, uint256 index);
    error NothingToSweep(uint256 epoch);
    error FeeOnTransfer(address token);
    error TokenNotContract(address token);
    error MetadataTooLong();
    error Insolvency(address token);

    event DistributionStarted(
        uint256 indexed epoch,
        address indexed token,
        bytes32 merkleRoot,
        uint256 totalAllocation,
        uint64 deadline,
        string metadataURI
    );
    event DistributionFunded(uint256 indexed epoch, address indexed from, uint256 amount);
    event Claimed(uint256 indexed epoch, uint256 index, address indexed account, uint256 amount);
    event Swept(uint256 indexed epoch, address indexed to, uint256 amount);
    event SurplusRecovered(address indexed token, address indexed to, uint256 amount);

    constructor(address timelock_) {
        if (timelock_ == address(0)) revert ZeroAddress();
        timelock = timelock_;
    }

    modifier onlyTimelock() {
        if (msg.sender != timelock) revert OnlyTimelock(msg.sender);
        _;
    }

    function distribution(uint256 epoch)
        external
        view
        returns (
            address token,
            bytes32 merkleRoot,
            uint256 totalAllocation,
            uint256 funded,
            uint256 claimed,
            uint64 deadline,
            bool swept,
            string memory metadataURI
        )
    {
        Distribution storage d = _distributions[epoch];
        return (d.token, d.merkleRoot, d.totalAllocation, d.funded, d.claimed, d.deadline, d.swept, d.metadataURI);
    }

    function isClaimed(uint256 epoch, uint256 index) public view returns (bool) {
        uint256 word = index >> 8;
        uint256 mask = uint256(1) << (index & 0xff);
        return (_claimed[epoch][word] & mask) != 0;
    }

    /// @notice Double-hashed ABI leaf. Use this exact function when building the tree.
    function hashLeaf(uint256 index, address account, uint256 amount) public pure returns (bytes32) {
        return keccak256(bytes.concat(keccak256(abi.encode(index, account, amount))));
    }

    /**
     * @notice Open an epoch. Timelock only, which means an executed proposal.
     * @param totalAllocation Sum of every leaf. Claims are closed until `fund` has delivered this amount.
     * @param deadline Unix time. Claims are allowed through this second. Sweep is allowed after it.
     * @param metadataURI Off-chain pointer to the tree (for example an IPFS CID). Not read by the contract.
     */
    function startDistribution(
        address token,
        bytes32 merkleRoot,
        uint256 totalAllocation,
        uint64 deadline,
        string calldata metadataURI
    ) external onlyTimelock returns (uint256 epoch) {
        if (token == address(0) || merkleRoot == bytes32(0) || totalAllocation == 0) {
            revert ZeroValue();
        }
        if (token.code.length == 0) revert TokenNotContract(token);
        if (deadline <= block.timestamp) revert DeadlinePassed(type(uint256).max);
        if (bytes(metadataURI).length > 1024) revert MetadataTooLong();

        epoch = distributionCount;
        distributionCount = epoch + 1;
        Distribution storage d = _distributions[epoch];
        d.token = token;
        d.merkleRoot = merkleRoot;
        d.totalAllocation = totalAllocation;
        d.deadline = deadline;
        d.metadataURI = metadataURI;

        emit DistributionStarted(epoch, token, merkleRoot, totalAllocation, deadline, metadataURI);
    }

    /// @notice Pull `amount` of the epoch token from the caller. Anyone can fund. No partial claims.
    function fund(uint256 epoch, uint256 amount) external nonReentrant {
        Distribution storage d = _distributions[epoch];
        if (d.merkleRoot == bytes32(0)) revert UnknownEpoch(epoch);
        if (d.swept) revert AlreadySwept(epoch);
        if (block.timestamp > d.deadline) revert DeadlinePassed(epoch);
        if (amount == 0) revert ZeroValue();
        uint256 next = d.funded + amount;
        if (next > d.totalAllocation) revert Overfund(epoch, next, d.totalAllocation);

        uint256 beforeBal = IERC20(d.token).balanceOf(address(this));
        IERC20(d.token).safeTransferFrom(msg.sender, address(this), amount);
        uint256 received = IERC20(d.token).balanceOf(address(this)) - beforeBal;
        if (received != amount) revert FeeOnTransfer(d.token);

        d.funded = next;
        reserved[d.token] += amount;
        emit DistributionFunded(epoch, msg.sender, amount);
    }

    /**
     * @notice Pay one leaf. Anyone may submit the proof. Tokens go to `account`.
     * Gas does not grow with the number of holders. A 5,000-leaf tree is a proof of about 13 hashes.
     */
    function claim(uint256 epoch, uint256 index, address account, uint256 amount, bytes32[] calldata proof)
        external
        nonReentrant
    {
        Distribution storage d = _distributions[epoch];
        if (d.merkleRoot == bytes32(0)) revert UnknownEpoch(epoch);
        if (d.swept) revert AlreadySwept(epoch);
        if (block.timestamp > d.deadline) revert DeadlinePassed(epoch);
        if (account == address(0) || amount == 0) revert ZeroValue();
        if (d.funded != d.totalAllocation) revert NotFullyFunded(epoch);
        if (isClaimed(epoch, index)) revert AlreadyClaimed(epoch, index);
        if (d.claimed + amount > d.funded) revert AllocationExceeded(epoch);

        bytes32 leaf = hashLeaf(index, account, amount);
        if (!MerkleProof.verifyCalldata(proof, d.merkleRoot, leaf)) revert InvalidProof(epoch, index);

        _setClaimed(epoch, index);
        d.claimed += amount;
        reserved[d.token] -= amount;
        IERC20(d.token).safeTransfer(account, amount);
        emit Claimed(epoch, index, account, amount);
    }

    /// @notice After the deadline, send whatever was funded and not claimed. Timelock only.
    function sweep(uint256 epoch, address to) external onlyTimelock nonReentrant returns (uint256 amount) {
        Distribution storage d = _distributions[epoch];
        if (d.merkleRoot == bytes32(0)) revert UnknownEpoch(epoch);
        if (d.swept) revert AlreadySwept(epoch);
        if (block.timestamp <= d.deadline) revert DeadlineNotReached(epoch);
        if (to == address(0)) revert ZeroAddress();

        amount = d.funded - d.claimed;
        if (amount == 0) revert NothingToSweep(epoch);

        d.swept = true;
        d.funded = d.claimed;
        reserved[d.token] -= amount;
        IERC20(d.token).safeTransfer(to, amount);
        emit Swept(epoch, to, amount);
    }

    /**
     * @notice Send tokens that are in the contract but not reserved for an open epoch.
     * This covers a plain ERC-20 transfer that skipped {fund}. It cannot touch reserved funds.
     */
    function recoverSurplus(address token, address to) external onlyTimelock nonReentrant returns (uint256 amount) {
        if (token == address(0) || to == address(0)) revert ZeroAddress();
        uint256 balance = IERC20(token).balanceOf(address(this));
        uint256 held = reserved[token];
        if (balance < held) revert Insolvency(token);
        amount = balance - held;
        if (amount == 0) revert ZeroValue();
        IERC20(token).safeTransfer(to, amount);
        emit SurplusRecovered(token, to, amount);
    }

    function _setClaimed(uint256 epoch, uint256 index) private {
        uint256 word = index >> 8;
        uint256 mask = uint256(1) << (index & 0xff);
        _claimed[epoch][word] |= mask;
    }
}
