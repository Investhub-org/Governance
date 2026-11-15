// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal ERC-6372 block-number clock. The factory must reject it.
contract BlockNumberVotes {
    function clock() external view returns (uint48) {
        return uint48(block.number);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() external pure returns (string memory) {
        return "mode=blocknumber&from=default";
    }

    function getVotes(address) external pure returns (uint256) {
        return 0;
    }

    function totalSupply() external pure returns (uint256) {
        return 0;
    }
}
