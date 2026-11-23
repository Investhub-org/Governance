// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { GvChainGuard } from "./GvChainGuard.sol";
import { GvFactoryBootstrap } from "./GvFactoryBootstrap.sol";
import { GvDirectory } from "../src/GvDirectory.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";

/**
 * @notice Deploy the shared factory, its eleven CREATE2 deployers, and the optional directory.
 *
 * Local and testnet only. {GvChainGuard} reverts on every other chain id, including Base mainnet.
 * This script does nothing unless you provide a key and the confirmation string.
 * It does not broadcast unless you pass `--broadcast`. It has no default key.
 *
 *   anvil
 *   DEPLOYER_PRIVATE_KEY=0x… GV_CONFIRM=deploy-gv-infrastructure \
 *     forge script script/DeployInfrastructure.s.sol --rpc-url http://127.0.0.1:8545 --broadcast
 *
 * Base Sepolia is chain id 84532 (`https://sepolia.base.org`). Do not point this script at mainnet.
 *
 * Do not send any other transaction from that key while the script runs. The factory
 * address is predicted from the key's next nonce plus 11. Send no member address and no secret
 * into the repository.
 */
contract DeployInfrastructure is Script {
    function run() external {
        GvChainGuard.requireLocalOrTestnet();
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        string memory confirm = vm.envString("GV_CONFIRM");
        if (keccak256(bytes(confirm)) != keccak256("deploy-gv-infrastructure")) {
            revert("set GV_CONFIRM=deploy-gv-infrastructure");
        }

        address broadcaster = vm.addr(pk);
        vm.startBroadcast(pk);
        GvKitFactory factory = GvFactoryBootstrap.deploy(vm, broadcaster);
        GvDirectory directory = GvFactoryBootstrap.deployDirectory();
        vm.stopBroadcast();

        console2.log("broadcaster", broadcaster);
        console2.log("chainId", block.chainid);
        console2.log("shareDeployer", address(factory.shareDeployer()));
        console2.log("wrapperDeployer", address(factory.wrapperDeployer()));
        console2.log("timelockDeployer", address(factory.timelockDeployer()));
        console2.log("governorDeployer", address(factory.governorDeployer()));
        console2.log("dividendDeployer", address(factory.dividendDeployer()));
        console2.log("rulesDeployer", address(factory.rulesDeployer()));
        console2.log("assemblyDeployer", address(factory.assemblyDeployer()));
        console2.log("informationDeployer", address(factory.informationDeployer()));
        console2.log("termsDeployer", address(factory.termsDeployer()));
        console2.log("acquisitionDeployer", address(factory.acquisitionDeployer()));
        console2.log("recoveryDeployer", address(factory.recoveryDeployer()));
        console2.log("factory", address(factory));
        console2.log("directory", address(directory));
    }
}
