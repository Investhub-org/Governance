// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { GvDirectory } from "../src/GvDirectory.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import {
    GvDividendDeployer,
    GvGovernorDeployer,
    GvShareDeployer,
    GvTimelockDeployer,
    GvVotesWrapperDeployer
} from "../src/deployers/GvDeployers.sol";

/**
 * @notice Deploy the shared factory, its five CREATE2 deployers, and the optional directory.
 *
 * This script does nothing unless you provide a key and the confirmation string.
 * It does not broadcast unless you pass `--broadcast`. It has no default key.
 *
 *   DEPLOYER_PRIVATE_KEY=0x… GV_CONFIRM=deploy-gv-infrastructure \
 *     forge script script/DeployInfrastructure.s.sol --rpc-url "$BASE_RPC_URL" --broadcast
 *
 * Do not send any other transaction from that key while the script runs. The factory
 * address is predicted from the key's next nonce. Send no member address and no secret
 * into the repository.
 */
contract DeployInfrastructure is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory confirm = vm.envString("GV_CONFIRM");
        if (keccak256(bytes(confirm)) != keccak256("deploy-gv-infrastructure")) {
            revert("set GV_CONFIRM=deploy-gv-infrastructure");
        }

        address broadcaster = vm.addr(pk);
        uint256 nonce = vm.getNonce(broadcaster);
        address predictedFactory = vm.computeCreateAddress(broadcaster, nonce + 5);

        vm.startBroadcast(pk);
        GvShareDeployer shareD = new GvShareDeployer(predictedFactory);
        GvVotesWrapperDeployer wrapD = new GvVotesWrapperDeployer(predictedFactory);
        GvTimelockDeployer timeD = new GvTimelockDeployer(predictedFactory);
        GvGovernorDeployer govD = new GvGovernorDeployer(predictedFactory);
        GvDividendDeployer divD = new GvDividendDeployer(predictedFactory);
        GvKitFactory factory = new GvKitFactory(shareD, wrapD, timeD, govD, divD);
        GvDirectory directory = new GvDirectory();
        vm.stopBroadcast();

        if (address(factory) != predictedFactory) revert("factory address mismatch");

        console2.log("broadcaster", broadcaster);
        console2.log("shareDeployer", address(shareD));
        console2.log("wrapperDeployer", address(wrapD));
        console2.log("timelockDeployer", address(timeD));
        console2.log("governorDeployer", address(govD));
        console2.log("dividendDeployer", address(divD));
        console2.log("factory", address(factory));
        console2.log("directory", address(directory));
    }
}
