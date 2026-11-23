// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Test } from "forge-std/Test.sol";
import { console2 } from "forge-std/console2.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { IERC20Metadata } from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import { IGovernor } from "@openzeppelin/contracts/governance/IGovernor.sol";
import { GvAssembly } from "../src/GvAssembly.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvDividend } from "../src/GvDividend.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvFactoryBootstrap } from "../script/GvFactoryBootstrap.sol";
import { MerkleBuilder } from "./MerkleBuilder.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/**
 * @notice Base mainnet fork of propose, vote, queue, execute, fund, and claim.
 * Skipped when BASE_RPC_URL is unset. The fork never broadcasts.
 * Circle USDC on Base is a token contract, not a wallet. No holder address is hardcoded.
 */
contract GvForkTest is Test {
    /// @dev Circle FiatToken proxy on Base. A contract address, not an account.
    address internal constant BASE_USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;

    function testFork_base_propose_vote_queue_execute_fund_claim() public {
        string memory rpc = vm.envOr("BASE_RPC_URL", string(""));
        if (bytes(rpc).length == 0) {
            vm.skip(true, "BASE_RPC_URL is not set");
            return;
        }
        vm.createSelectFork(rpc);
        _assertBase();
        (GvGovernor governor, GvDividend dividend) = _deployOnFork();
        _voteAndDistribute(governor, dividend);
    }

    function _deployFactory() internal returns (GvKitFactory deployed) {
        deployed = GvFactoryBootstrap.deploy(vm, address(this));
    }

    function _assertBase() internal view {
        assertEq(block.chainid, 8453);
        assertEq(IERC20Metadata(BASE_USDC).symbol(), "USDC");
        assertEq(IERC20Metadata(BASE_USDC).decimals(), 6);
    }

    function _deployOnFork() internal returns (GvGovernor governor, GvDividend dividend) {
        GvKitFactory factory = _deployFactory();
        (address share, address governorAddr, address timelock, address dividendAddr) = factory.deploy(
            GvKitFactory.ShareSpec({
                name: "Fork Test Shares",
                symbol: "FTS",
                decimals: 0,
                initialSupply: 100,
                existingUnderlying: address(0),
                existingVotesToken: address(0)
            }),
            GvKitFactory.GovSpec({
                name: "Fork Test Governor",
                votingDelay: 1,
                votingPeriod: 3600,
                proposalThreshold: 1,
                quorumNumerator: 4,
                timelockDelay: 1
            }),
            "ipfs://gv-kit-fork-test",
            bytes32("fork")
        );
        assertEq(GvShare(share).timelock(), timelock);
        assertFalse(TimelockLike(timelock).hasRole(TimelockLike(timelock).DEFAULT_ADMIN_ROLE(), address(factory)));
        GvShare(share).delegate(address(this));
        vm.warp(vm.getBlockTimestamp() + 1);
        governor = GvGovernor(payable(governorAddr));
        dividend = GvDividend(dividendAddr);
        GvCompanyRules rules = new GvCompanyRules(address(this));
        GvAssembly assemblyGv = new GvAssembly(address(this), IERC20(share), rules, governor);
        governor.setArticlesGate(address(assemblyGv));
        console2.log("fork governor", governorAddr);
    }

    function _voteAndDistribute(GvGovernor governor, GvDividend dividend) internal {
        address claimant = makeAddr("fork-claimant");
        uint256 payout = 10_000_000;
        bytes32 root = _singleRoot(dividend, claimant, payout);
        address payToken = _fundToken(payout);
        uint64 deadline = uint64(vm.getBlockTimestamp() + 14 days);

        address[] memory targets = new address[](1);
        targets[0] = address(dividend);
        uint256[] memory values = new uint256[](1);
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] =
            abi.encodeCall(GvDividend.startDistribution, (payToken, root, payout, deadline, "ipfs://fork-dividend"));
        string memory description = "TEST dividend on a Base fork. Not an offering.";
        uint256 id = governor.propose(targets, values, calldatas, description);
        _finish(governor, id, targets, values, calldatas, description);
        _pay(dividend, payToken, claimant, payout);
        console2.log("fork pay token", payToken);
    }

    function _singleRoot(GvDividend dividend, address claimant, uint256 payout) internal pure returns (bytes32) {
        bytes32[] memory leaves = new bytes32[](1);
        leaves[0] = dividend.hashLeaf(0, claimant, payout);
        return MerkleBuilder.root(MerkleBuilder.build(leaves));
    }

    function _finish(
        GvGovernor governor,
        uint256 id,
        address[] memory targets,
        uint256[] memory values,
        bytes[] memory calldatas,
        string memory description
    ) internal {
        vm.warp(governor.proposalSnapshot(id) + 1);
        governor.castVote(id, 1);
        vm.warp(governor.proposalDeadline(id) + 1);
        bytes32 descHash = keccak256(bytes(description));
        governor.queue(targets, values, calldatas, descHash);
        vm.warp(governor.proposalEta(id));
        governor.execute(targets, values, calldatas, descHash);
        assertEq(uint256(governor.state(id)), uint256(IGovernor.ProposalState.Executed));
    }

    function _pay(GvDividend dividend, address payToken, address claimant, uint256 payout) internal {
        IERC20(payToken).approve(address(dividend), payout);
        dividend.fund(0, payout);
        dividend.claim(0, 0, claimant, payout, new bytes32[](0));
        assertEq(IERC20(payToken).balanceOf(claimant), payout);
    }

    /// @dev Prefer canonical Base USDC when Foundry can set a test balance. Otherwise use a test ERC-20 on the fork.
    function _fundToken(uint256 amount) internal returns (address) {
        try this.tryDealUsdc(amount) returns (bool ok) {
            if (ok && IERC20(BASE_USDC).balanceOf(address(this)) >= amount) {
                console2.log("funded canonical Base USDC");
                return BASE_USDC;
            }
        } catch {
            console2.log("Base USDC balance write was not usable; funding a test ERC-20 on the fork");
        }
        MockERC20 mock = new MockERC20("USD Coin", "USDC", 6);
        mock.mint(address(this), amount);
        return address(mock);
    }

    function tryDealUsdc(uint256 amount) external returns (bool) {
        deal(BASE_USDC, address(this), amount);
        return IERC20(BASE_USDC).balanceOf(address(this)) == amount;
    }
}

interface TimelockLike {
    function DEFAULT_ADMIN_ROLE() external view returns (bytes32);
    function hasRole(bytes32 role, address account) external view returns (bool);
}
