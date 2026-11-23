// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Vm } from "forge-std/Vm.sol";
import { GvDirectory } from "../src/GvDirectory.sol";
import { GvKitFactory } from "../src/GvKitFactory.sol";
import {
    GvDividendDeployer,
    GvGovernorDeployer,
    GvShareDeployer,
    GvTimelockDeployer,
    GvVotesWrapperDeployer
} from "../src/deployers/GvDeployers.sol";
import {
    GvAcquisitionDeployer,
    GvAssemblyDeployer,
    GvCompanyRulesDeployer,
    GvInformationDeployer,
    GvRecoveryDeployer,
    GvShareTermsDeployer
} from "../src/deployers/GvModuleDeployers.sol";

/**
 * @notice CREATE the eleven deployers and the factory from the calling account.
 * The factory address is CREATE at that account's nonce + 11. Send no other
 * transaction from the account until the factory transaction is mined.
 * The directory is a twelfth contract and is not part of the factory address.
 */
library GvFactoryBootstrap {
    error FactoryAddressMismatch(address predicted, address actual);

    /// @param deployer Account that executes the CREATE opcodes. Under `vm.prank` or
    /// `vm.startBroadcast` that is the pranked or broadcasting account, not `address(this)`.
    function deploy(Vm vm, address deployer) internal returns (GvKitFactory factory) {
        uint256 nonce = vm.getNonce(deployer);
        address predicted = vm.computeCreateAddress(deployer, nonce + 11);
        new GvShareDeployer(predicted);
        new GvVotesWrapperDeployer(predicted);
        new GvTimelockDeployer(predicted);
        new GvGovernorDeployer(predicted);
        new GvDividendDeployer(predicted);
        new GvCompanyRulesDeployer(predicted);
        new GvAssemblyDeployer(predicted);
        new GvInformationDeployer(predicted);
        new GvShareTermsDeployer(predicted);
        new GvAcquisitionDeployer(predicted);
        new GvRecoveryDeployer(predicted);
        factory = new GvKitFactory(
            GvShareDeployer(vm.computeCreateAddress(deployer, nonce)),
            GvVotesWrapperDeployer(vm.computeCreateAddress(deployer, nonce + 1)),
            GvTimelockDeployer(vm.computeCreateAddress(deployer, nonce + 2)),
            GvGovernorDeployer(vm.computeCreateAddress(deployer, nonce + 3)),
            GvDividendDeployer(vm.computeCreateAddress(deployer, nonce + 4)),
            GvCompanyRulesDeployer(vm.computeCreateAddress(deployer, nonce + 5)),
            GvAssemblyDeployer(vm.computeCreateAddress(deployer, nonce + 6)),
            GvInformationDeployer(vm.computeCreateAddress(deployer, nonce + 7)),
            GvShareTermsDeployer(vm.computeCreateAddress(deployer, nonce + 8)),
            GvAcquisitionDeployer(vm.computeCreateAddress(deployer, nonce + 9)),
            GvRecoveryDeployer(vm.computeCreateAddress(deployer, nonce + 10))
        );
        if (address(factory) != predicted) revert FactoryAddressMismatch(predicted, address(factory));
    }

    function deployDirectory() internal returns (GvDirectory) {
        return new GvDirectory();
    }
}
