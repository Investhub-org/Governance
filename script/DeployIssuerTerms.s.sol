// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Script, console2 } from "forge-std/Script.sol";
import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { GvAcquisition } from "../src/GvAcquisition.sol";
import { GvAssembly } from "../src/GvAssembly.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvInformation } from "../src/GvInformation.sol";
import { GvRecovery } from "../src/GvRecovery.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvShareTerms } from "../src/GvShareTerms.sol";

/**
 * @notice Deploy one issuer's rules, meeting record, information record, share terms,
 * acquisition contract, and recovery contract. The broadcaster becomes their owner
 * where a contract has an owner. GvAcquisition has no owner.
 *
 * This does not call the share token. Only the kit timelock can set the transfer policy
 * and the share modules, and only by an executed proposal. The script loads the
 * placeholder parameters. Replace them before anyone relies on them. See docs/legal-wrapper.md.
 *
 * Required environment: DEPLOYER_PRIVATE_KEY, GV_CONFIRM=deploy-gv-terms,
 * GV_SHARE, GV_GOVERNOR, GV_TIMELOCK, GV_CONSIDERATION.
 *
 *   forge script script/DeployIssuerTerms.s.sol --rpc-url "$BASE_RPC_URL" --broadcast
 *
 * Without `--broadcast` the script only simulates. There is no default key.
 */
contract DeployIssuerTerms is Script {
    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        _requireConfirm(vm.envString("GV_CONFIRM"));
        address issuer = vm.addr(pk);
        GvShare share = GvShare(vm.envAddress("GV_SHARE"));
        GvGovernor governor = GvGovernor(payable(vm.envAddress("GV_GOVERNOR")));
        address timelock = vm.envAddress("GV_TIMELOCK");
        address consideration = vm.envAddress("GV_CONSIDERATION");

        vm.startBroadcast(pk);
        _deploy(issuer, share, governor, timelock, consideration);
        vm.stopBroadcast();
    }

    function _requireConfirm(string memory confirm) internal pure {
        if (keccak256(bytes(confirm)) != keccak256("deploy-gv-terms")) {
            revert("set GV_CONFIRM=deploy-gv-terms");
        }
    }

    function _deploy(address issuer, GvShare share, GvGovernor governor, address timelock, address consideration)
        internal
    {
        GvCompanyRules rules = new GvCompanyRules(issuer);
        GvAssembly assemblyGv = new GvAssembly(issuer, IERC20(address(share)), rules, governor);
        GvInformation info = new GvInformation(IERC20(address(share)), rules, assemblyGv);
        GvShareTerms terms = new GvShareTerms(issuer, share, rules, consideration);
        GvAcquisition acquisition = new GvAcquisition(share, rules, terms);
        terms.setAcquisition(address(acquisition));
        GvRecovery recovery = new GvRecovery(share, rules, terms, assemblyGv, timelock);
        console2.log("issuer", issuer);
        console2.log("rules", address(rules));
        console2.log("assembly", address(assemblyGv));
        console2.log("information", address(info));
        console2.log("terms", address(terms));
        console2.log("acquisition", address(acquisition));
        console2.log("recovery", address(recovery));
    }
}
