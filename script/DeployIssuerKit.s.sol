// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";

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
 *   forge script script/DeployIssuerKit.s.sol --rpc-url "$BASE_RPC_URL" --broadcast
 *
 * Without `--broadcast` the script only simulates. There is no default key.
 */
contract DeployIssuerKit is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory confirm = vm.envString("GV_CONFIRM");
        if (keccak256(bytes(confirm)) != keccak256("deploy-gv-kit")) {
            revert("set GV_CONFIRM=deploy-gv-kit");
        }

        GvKitFactory factory = GvKitFactory(vm.envAddress("GV_FACTORY"));
        GvKitFactory.ShareSpec memory shareSpec = _shareSpec();
        uint256 votingDelay = vm.envUint("GV_VOTING_DELAY");
        uint256 votingPeriod = vm.envUint("GV_VOTING_PERIOD");
        uint256 quorum = vm.envUint("GV_QUORUM_NUMERATOR");
        if (votingDelay == 0 || votingDelay > type(uint48).max) revert("GV_VOTING_DELAY out of range");
        if (votingPeriod == 0 || votingPeriod > type(uint32).max) revert("GV_VOTING_PERIOD out of range");
        if (quorum == 0 || quorum > 100) revert("GV_QUORUM_NUMERATOR must be 1 to 100");
        GvKitFactory.GovSpec memory govSpec = GvKitFactory.GovSpec({
            name: vm.envString("GV_GOV_NAME"),
            votingDelay: uint48(votingDelay),
            votingPeriod: uint32(votingPeriod),
            proposalThreshold: vm.envUint("GV_PROPOSAL_THRESHOLD"),
            quorumNumerator: quorum,
            timelockDelay: vm.envUint("GV_TIMELOCK_DELAY")
        });
        string memory metadataURI = vm.envString("GV_METADATA_URI");
        bytes32 salt = vm.envBytes32("GV_SALT");
        if (bytes(metadataURI).length == 0) revert("GV_METADATA_URI is empty");

        address issuer = vm.addr(pk);
        (address predictedShare, address predictedGov, address predictedTl, address predictedDiv) =
            factory.predict(issuer, shareSpec, govSpec, salt);
        console2.log("predicted share", predictedShare);
        console2.log("predicted governor", predictedGov);
        console2.log("predicted timelock", predictedTl);
        console2.log("predicted dividend", predictedDiv);

        vm.startBroadcast(pk);
        (address share, address governor, address timelock, address dividend) =
            factory.deploy(shareSpec, govSpec, metadataURI, salt);
        vm.stopBroadcast();

        if (share != predictedShare || governor != predictedGov || timelock != predictedTl || dividend != predictedDiv)
        {
            revert("deployed addresses do not match predict");
        }
        console2.log("issuer", issuer);
        console2.log("share", share);
        console2.log("governor", governor);
        console2.log("timelock", timelock);
        console2.log("dividend", dividend);
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
