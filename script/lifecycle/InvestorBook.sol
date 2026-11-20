// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Deterministic investor book shared with `sim/generate.py`.
/// Addresses are the last 20 bytes of a keccak. They are not secp256k1 accounts and have no key.
/// The head of the cap table is fixed in basis points. The tail is Zipf with weight `1e6 / (rank + 1)`.
/// Integer division matches the Python generator. Keep the constants in lockstep with that file.
library InvestorBook {
    uint256 internal constant SUPPLY = 1_000_000;
    uint256 internal constant HEAD_COUNT = 5;
    uint256 internal constant MIN_HOLDERS = 8;
    uint256 internal constant MAX_HOLDERS = 5000;
    /// @dev USDC base units (6 decimals) paid per share, both as the simulated subscription price and the sale price.
    uint256 internal constant PRICE = 1_000_000;
    /// @dev USDC base units of dividend per share. One whole token per share.
    uint256 internal constant DIVIDEND_PER_SHARE = 1_000_000;
    uint256 internal constant PREEMPTION_AMOUNT = 10_000;
    uint256 internal constant PREEMPTION_EXERCISE = 1000;
    uint256 internal constant TAG_STAKE = 300_000;
    uint256 internal constant TAG_JOIN = 1000;
    bytes32 internal constant KIT_SALT = keccak256("gv-sim-lifecycle-v1");

    error BadHolderCount(uint256 holders);
    error AllocationMismatch(uint256 got, uint256 want);

    function investor(uint256 index) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("gv-sim-investor-v1", index)))));
    }

    function role(string memory name) internal pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked("gv-sim-role-v1", name)))));
    }

    function dividendOf(uint256 shares) internal pure returns (uint256) {
        return shares * DIVIDEND_PER_SHARE;
    }

    /// @dev Head is 32%, 18%, 12%, 10%, 8%. The remaining 20% is Zipf across `holders - 5` accounts.
    function allocate(uint256 holders) internal pure returns (uint256[] memory shares) {
        if (holders < MIN_HOLDERS || holders > MAX_HOLDERS) revert BadHolderCount(holders);
        shares = new uint256[](holders);
        uint16[5] memory bps = [uint16(3200), 1800, 1200, 1000, 800];
        uint256 headSum;
        for (uint256 index; index < HEAD_COUNT; ++index) {
            shares[index] = SUPPLY * bps[index] / 10_000;
            headSum += shares[index];
        }
        uint256 tailSupply = SUPPLY - headSum;
        uint256 tailCount = holders - HEAD_COUNT;
        uint256 sumWeights;
        for (uint256 rank; rank < tailCount; ++rank) {
            sumWeights += _weight(rank);
        }
        uint256 allocated;
        for (uint256 rank; rank < tailCount; ++rank) {
            uint256 part = tailSupply * _weight(rank) / sumWeights;
            if (part == 0) part = 1;
            shares[HEAD_COUNT + rank] = part;
            allocated += part;
        }
        if (allocated > tailSupply) {
            uint256 over = allocated - tailSupply;
            if (shares[HEAD_COUNT] <= over) revert AllocationMismatch(allocated, tailSupply);
            shares[HEAD_COUNT] -= over;
        } else if (allocated < tailSupply) {
            shares[HEAD_COUNT] += tailSupply - allocated;
        }
        uint256 sum;
        for (uint256 index; index < holders; ++index) {
            if (shares[index] == 0) revert AllocationMismatch(0, SUPPLY);
            sum += shares[index];
        }
        if (sum != SUPPLY) revert AllocationMismatch(sum, SUPPLY);
    }

    function _weight(uint256 rank) private pure returns (uint256) {
        return 1_000_000 / (rank + 1);
    }
}
