// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Off-chain-style tree used by the tests and checked against {GvDividend.hashLeaf}.
/// Pairs are sorted. An odd node is promoted without being hashed with itself.
library MerkleBuilder {
    function hashPair(bytes32 a, bytes32 b) internal pure returns (bytes32) {
        return a < b ? keccak256(abi.encodePacked(a, b)) : keccak256(abi.encodePacked(b, a));
    }

    function build(bytes32[] memory leaves) internal pure returns (bytes32[][] memory levels) {
        require(leaves.length > 0, "empty tree");
        uint256 depth = 1;
        uint256 n = leaves.length;
        while (n > 1) {
            n = (n + 1) / 2;
            depth++;
        }
        levels = new bytes32[][](depth);
        levels[0] = leaves;
        for (uint256 d; d + 1 < depth; ++d) {
            uint256 len = levels[d].length;
            bytes32[] memory next = new bytes32[]((len + 1) / 2);
            for (uint256 i; i < len; i += 2) {
                if (i + 1 == len) {
                    next[i / 2] = levels[d][i];
                } else {
                    next[i / 2] = hashPair(levels[d][i], levels[d][i + 1]);
                }
            }
            levels[d + 1] = next;
        }
    }

    function root(bytes32[][] memory levels) internal pure returns (bytes32) {
        return levels[levels.length - 1][0];
    }

    function proof(bytes32[][] memory levels, uint256 index) internal pure returns (bytes32[] memory) {
        bytes32[] memory buf = new bytes32[](levels.length - 1);
        uint256 count;
        uint256 idx = index;
        for (uint256 d; d + 1 < levels.length; ++d) {
            uint256 sibling = idx ^ 1;
            if (sibling < levels[d].length) {
                buf[count++] = levels[d][sibling];
            }
            idx /= 2;
        }
        bytes32[] memory out = new bytes32[](count);
        for (uint256 i; i < count; ++i) {
            out[i] = buf[i];
        }
        return out;
    }
}
