// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @notice Chain allowlist for forge scripts in this repository.
 * The scripts simulate and broadcast only on a local node or a public testnet.
 * There is no override. A mainnet chain id reverts before any broadcast.
 */
library GvChainGuard {
    error RefusingChain(uint256 chainId);

    function requireLocalOrTestnet() internal view {
        uint256 id = block.chainid;
        if (
            id == 31_337 || id == 1337 || id == 84_532 || id == 11_155_111 || id == 11_155_420 || id == 421_614
                || id == 80_002
        ) return;
        revert RefusingChain(id);
    }
}
