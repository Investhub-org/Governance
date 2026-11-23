// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import { GvChainGuard } from "./GvChainGuard.sol";

/**
 * @notice Deploy one issuer's full set from an existing factory: native share, governor, timelock,
 * dividend, and the rule modules. The broadcaster is the issuer and becomes the owner of the
 * Ownable modules. The factory keeps no admin role.
 *
 * Local and testnet only. {GvChainGuard} reverts on every other chain id. There is no mainnet override.
 * Without `--broadcast` the script only simulates. There is no default key.
 *
 * Required environment (see .env.example):
 *   DEPLOYER_PRIVATE_KEY, GV_CONFIRM=deploy-gv-issuer-set, GV_FACTORY,
 *   GV_NAME, GV_SYMBOL, GV_DECIMALS, GV_SUPPLY, GV_GOV_NAME,
 *   GV_VOTING_DELAY, GV_VOTING_PERIOD, GV_PROPOSAL_THRESHOLD, GV_QUORUM_NUMERATOR,
 *   GV_TIMELOCK_DELAY, GV_METADATA_URI, GV_SALT, GV_CONSIDERATION
 *
 * `GV_CONSIDERATION` is an ERC-20 that already exists on the target chain. The factory does not deploy it.
 * This script deploys a native share. Wrap mode and an existing votes token stay on DeployIssuerKit.
 *
 *   anvil --gas-limit 40000000
 *   DEPLOYER_PRIVATE_KEY=0x… GV_CONFIRM=deploy-gv-issuer-set \
 *     forge script script/DeployIssuerSet.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Anvil's default block gas limit is 30,000,000. Foundry sets this broadcast's gas limit from the
 * script estimate, which is higher than the gas the transaction uses, and a default node rejects
 * that limit. Raise the node's block gas limit as above. The call itself is about 23 million gas.
 *
 * Base Sepolia: `--rpc-url https://sepolia.base.org` (chain id 84532). A chain that enforces the
 * EIP-7825 per-transaction cap (16,777,216 gas) cannot include this call. These scripts refuse mainnet.
 */
interface IGvIssuerSet {
    function predictSet(
        address issuer,
        GvKitFactory.ShareSpec calldata shareSpec,
        GvKitFactory.GovSpec calldata govSpec,
        address consideration,
        bytes32 salt
    ) external view returns (GvKitFactory.PredictedSet memory);

    function deploySet(
        GvKitFactory.ShareSpec calldata shareSpec,
        GvKitFactory.GovSpec calldata govSpec,
        string calldata metadataURI,
        address consideration,
        bytes32 salt
    ) external returns (GvKitFactory.PredictedSet memory);
}

contract DeployIssuerSet is Script {
    function run() external {
        GvChainGuard.requireLocalOrTestnet();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        _requireConfirm(vm.envString("GV_CONFIRM"));
        _run(pk);
    }

    function _requireConfirm(string memory confirm) internal pure {
        if (keccak256(bytes(confirm)) != keccak256("deploy-gv-issuer-set")) {
            revert("set GV_CONFIRM=deploy-gv-issuer-set");
        }
    }

    function _run(uint256 pk) internal {
        IGvIssuerSet factory = IGvIssuerSet(vm.envAddress("GV_FACTORY"));
        GvKitFactory.ShareSpec memory shareSpec = _shareSpec();
        GvKitFactory.GovSpec memory govSpec = _govSpec();
        string memory metadataURI = vm.envString("GV_METADATA_URI");
        bytes32 salt = vm.envBytes32("GV_SALT");
        address consideration = vm.envAddress("GV_CONSIDERATION");
        if (bytes(metadataURI).length == 0) revert("GV_METADATA_URI is empty");
        if (consideration == address(0)) revert("GV_CONSIDERATION is empty");

        address issuer = vm.addr(pk);
        GvKitFactory.PredictedSet memory predicted = factory.predictSet(issuer, shareSpec, govSpec, consideration, salt);
        _log("predicted", predicted);

        vm.startBroadcast(pk);
        GvKitFactory.PredictedSet memory deployed =
            factory.deploySet(shareSpec, govSpec, metadataURI, consideration, salt);
        vm.stopBroadcast();

        _assertMatch(predicted, deployed);
        console2.log("issuer", issuer);
        console2.log("chainId", block.chainid);
        _log("deployed", deployed);
    }

    function _shareSpec() internal view returns (GvKitFactory.ShareSpec memory spec) {
        spec.name = vm.envString("GV_NAME");
        spec.symbol = vm.envString("GV_SYMBOL");
        spec.decimals = _decimals();
        spec.initialSupply = vm.envUint("GV_SUPPLY");
    }

    function _govSpec() internal view returns (GvKitFactory.GovSpec memory govSpec) {
        uint256 votingDelay = vm.envUint("GV_VOTING_DELAY");
        uint256 votingPeriod = vm.envUint("GV_VOTING_PERIOD");
        uint256 quorum = vm.envUint("GV_QUORUM_NUMERATOR");
        if (votingDelay == 0 || votingDelay > type(uint48).max) revert("GV_VOTING_DELAY out of range");
        if (votingPeriod == 0 || votingPeriod > type(uint32).max) revert("GV_VOTING_PERIOD out of range");
        if (quorum == 0 || quorum > 100) revert("GV_QUORUM_NUMERATOR must be 1 to 100");
        govSpec = GvKitFactory.GovSpec({
            name: vm.envString("GV_GOV_NAME"),
            votingDelay: uint48(votingDelay),
            votingPeriod: uint32(votingPeriod),
            proposalThreshold: vm.envUint("GV_PROPOSAL_THRESHOLD"),
            quorumNumerator: quorum,
            timelockDelay: vm.envUint("GV_TIMELOCK_DELAY")
        });
    }

    function _decimals() internal view returns (uint8) {
        uint256 decimals = vm.envUint("GV_DECIMALS");
        if (decimals > 18) revert("GV_DECIMALS must be 0 to 18");
        return uint8(decimals);
    }

    function _assertMatch(GvKitFactory.PredictedSet memory predicted, GvKitFactory.PredictedSet memory deployed)
        internal
        pure
    {
        if (
            predicted.share != deployed.share || predicted.governor != deployed.governor
                || predicted.timelock != deployed.timelock || predicted.dividend != deployed.dividend
                || predicted.rules != deployed.rules || predicted.assembly_ != deployed.assembly_
                || predicted.information != deployed.information || predicted.terms != deployed.terms
                || predicted.acquisition != deployed.acquisition || predicted.recovery != deployed.recovery
        ) revert("deployed addresses do not match predictSet");
    }

    function _log(string memory label, GvKitFactory.PredictedSet memory set) internal pure {
        console2.log(label, "share", set.share);
        console2.log(label, "governor", set.governor);
        console2.log(label, "timelock", set.timelock);
        console2.log(label, "dividend", set.dividend);
        console2.log(label, "rules", set.rules);
        console2.log(label, "assembly", set.assembly_);
        console2.log(label, "information", set.information);
        console2.log(label, "terms", set.terms);
        console2.log(label, "acquisition", set.acquisition);
        console2.log(label, "recovery", set.recovery);
    }
}
