// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { GvChainGuard } from "../script/GvChainGuard.sol";

contract ChainGuardCaller {
    function check() external view {
        GvChainGuard.requireLocalOrTestnet();
    }
}

contract GvChainGuardTest is Test {
    ChainGuardCaller internal caller;

    function setUp() public {
        caller = new ChainGuardCaller();
    }

    function test_allows_local_and_public_testnets() public {
        uint256[7] memory allowed = [uint256(31_337), 1337, 84_532, 11_155_111, 11_155_420, 421_614, 80_002];
        for (uint256 i; i < allowed.length; ++i) {
            vm.chainId(allowed[i]);
            caller.check();
        }
    }

    function test_refuses_mainnet_chain_ids() public {
        uint256[6] memory refused = [uint256(1), 8453, 10, 42_161, 137, 56];
        for (uint256 i; i < refused.length; ++i) {
            vm.chainId(refused[i]);
            vm.expectRevert(abi.encodeWithSelector(GvChainGuard.RefusingChain.selector, refused[i]));
            caller.check();
        }
    }

    function testFuzz_refuses_unlisted_chain_ids(uint64 chainId) public {
        vm.assume(
            chainId != 31_337 && chainId != 1337 && chainId != 84_532 && chainId != 11_155_111 && chainId != 11_155_420
                && chainId != 421_614 && chainId != 80_002
        );
        vm.chainId(chainId);
        vm.expectRevert(abi.encodeWithSelector(GvChainGuard.RefusingChain.selector, chainId));
        caller.check();
    }
}
