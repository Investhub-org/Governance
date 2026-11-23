// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import { GvChainGuard } from "./GvChainGuard.sol";

/**
 * @notice Deploy one issuer kit from an existing factory. The broadcaster is the issuer.
 *
 * The kit's timelock admin is the timelock itself. This key receives a native share's
 * initial supply and then has no admin role. The factory is not an admin either.
 *
 * Required environment (see .env.example):
 *   DEPLOYER_PRIVATE_KEY, GV_CONFIRM=deploy-gv-kit, GV_FACTORY, GV_TOKEN_MODE,
 *   GV_GOV_NAME, GV_VOTING_DELAY, GV_VOTING_PERIOD, GV_PROPOSAL_THRESHOLD,
 *   GV_QUORUM_NUMERATOR, GV_TIMELOCK_DELAY, GV_METADATA_URI, GV_SALT
 * Mode `native` also needs GV_NAME, GV_SYMBOL, GV_DECIMALS, GV_SUPPLY.
 * Mode `wrap` also needs GV_NAME, GV_SYMBOL, GV_EXISTING_UNDERLYING.
 * Mode `votes` also needs GV_EXISTING_VOTES.
 *
 *   forge script script/DeployIssuerKit.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Local and testnet only. {GvChainGuard} reverts on every other chain id. There is no mainnet override.
 * Without `--broadcast` the script only simulates. There is no default key.
 */
interface IGvKitDeploy {
    function predict(
        address issuer,
        GvKitFactory.ShareSpec calldata shareSpec,
        GvKitFactory.GovSpec calldata govSpec,
        bytes32 salt
    ) external view returns (address share, address governor, address timelock, address dividend);

    function deploy(
        GvKitFactory.ShareSpec calldata shareSpec,
        GvKitFactory.GovSpec calldata govSpec,
        string calldata metadataURI,
        bytes32 salt
    ) external returns (address share, address governor, address timelock, address dividend);
}

contract DeployIssuerKit is Script {
    function run() external {
        GvChainGuard.requireLocalOrTestnet();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        _requireConfirm(vm.envString("GV_CONFIRM"));
        _run(pk);
    }

    function _requireConfirm(string memory confirm) internal pure {
        if (keccak256(bytes(confirm)) != keccak256("deploy-gv-kit")) {
            revert("set GV_CONFIRM=deploy-gv-kit");
        }
    }

    struct Quad {
        address share;
        address governor;
        address timelock;
        address dividend;
    }

    function _run(uint256 pk) internal {
        IGvKitDeploy factory = IGvKitDeploy(vm.envAddress("GV_FACTORY"));
        GvKitFactory.ShareSpec memory shareSpec = _shareSpec();
        GvKitFactory.GovSpec memory govSpec = _govSpec();
        string memory metadataURI = vm.envString("GV_METADATA_URI");
        bytes32 salt = vm.envBytes32("GV_SALT");
        if (bytes(metadataURI).length == 0) revert("GV_METADATA_URI is empty");
        _send(pk, factory, shareSpec, govSpec, metadataURI, salt);
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

    function _send(
        uint256 pk,
        IGvKitDeploy factory,
        GvKitFactory.ShareSpec memory shareSpec,
        GvKitFactory.GovSpec memory govSpec,
        string memory metadataURI,
        bytes32 salt
    ) internal {
        address issuer = vm.addr(pk);
        Quad memory predicted = _predict(factory, issuer, shareSpec, govSpec, salt);
        _logQuad("predicted", predicted);
        vm.startBroadcast(pk);
        Quad memory deployed = _deploy(factory, shareSpec, govSpec, metadataURI, salt);
        vm.stopBroadcast();
        if (
            deployed.share != predicted.share || deployed.governor != predicted.governor
                || deployed.timelock != predicted.timelock || deployed.dividend != predicted.dividend
        ) revert("deployed addresses do not match predict");
        console2.log("issuer", issuer);
        console2.log("chainId", block.chainid);
        _logQuad("deployed", deployed);
    }

    function _predict(
        IGvKitDeploy factory,
        address issuer,
        GvKitFactory.ShareSpec memory shareSpec,
        GvKitFactory.GovSpec memory govSpec,
        bytes32 salt
    ) internal view returns (Quad memory quad) {
        (quad.share, quad.governor, quad.timelock, quad.dividend) = factory.predict(issuer, shareSpec, govSpec, salt);
    }

    function _deploy(
        IGvKitDeploy factory,
        GvKitFactory.ShareSpec memory shareSpec,
        GvKitFactory.GovSpec memory govSpec,
        string memory metadataURI,
        bytes32 salt
    ) internal returns (Quad memory quad) {
        (quad.share, quad.governor, quad.timelock, quad.dividend) =
            factory.deploy(shareSpec, govSpec, metadataURI, salt);
    }

    function _logQuad(string memory label, Quad memory quad) internal pure {
        console2.log(label, "share", quad.share);
        console2.log(label, "governor", quad.governor);
        console2.log(label, "timelock", quad.timelock);
        console2.log(label, "dividend", quad.dividend);
    }

    function _shareSpec() internal view returns (GvKitFactory.ShareSpec memory spec) {
        string memory mode = vm.envString("GV_TOKEN_MODE");
        bytes32 modeHash = keccak256(bytes(mode));
        if (modeHash == keccak256("native")) {
            spec.name = vm.envString("GV_NAME");
            spec.symbol = vm.envString("GV_SYMBOL");
            spec.decimals = _decimals();
            spec.initialSupply = vm.envUint("GV_SUPPLY");
        } else if (modeHash == keccak256("wrap")) {
            spec.name = vm.envString("GV_NAME");
            spec.symbol = vm.envString("GV_SYMBOL");
            spec.existingUnderlying = vm.envAddress("GV_EXISTING_UNDERLYING");
        } else if (modeHash == keccak256("votes")) {
            spec.existingVotesToken = vm.envAddress("GV_EXISTING_VOTES");
        } else {
            revert("GV_TOKEN_MODE must be native, wrap, or votes");
        }
    }

    function _decimals() internal view returns (uint8) {
        uint256 decimals = vm.envUint("GV_DECIMALS");
        if (decimals > 18) revert("GV_DECIMALS must be 0 to 18");
        return uint8(decimals);
    }
}
