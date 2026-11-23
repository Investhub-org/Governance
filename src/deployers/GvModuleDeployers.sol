// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GvAcquisition } from "../GvAcquisition.sol";
import { GvAssembly } from "../GvAssembly.sol";
import { GvCompanyRules } from "../GvCompanyRules.sol";
import { GvInformation } from "../GvInformation.sol";
import { GvRecovery } from "../GvRecovery.sol";
import { GvShareTerms } from "../GvShareTerms.sol";
import { GvCreate2Deployer } from "./GvDeployers.sol";

/**
 * @notice CREATE2 helpers for the rule modules. The factory is the only caller.
 * Each deployer is its own contract so the factory initcode stays under EIP-3860.
 * A deployer holds no role on the module it creates.
 */

contract GvCompanyRulesDeployer is GvCreate2Deployer {
    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(address issuer) external pure returns (bytes memory) {
        return abi.encodePacked(type(GvCompanyRules).creationCode, abi.encode(issuer));
    }

    function deploy(bytes32 salt, address issuer) external onlyFactory returns (address) {
        return _create2(abi.encodePacked(type(GvCompanyRules).creationCode, abi.encode(issuer)), salt);
    }
}

contract GvAssemblyDeployer is GvCreate2Deployer {
    struct AssemblyInit {
        address issuer;
        address token;
        address rules;
        address governor;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(AssemblyInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, AssemblyInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(AssemblyInit calldata cfg) internal pure returns (bytes memory) {
        return
            abi.encodePacked(type(GvAssembly).creationCode, abi.encode(cfg.issuer, cfg.token, cfg.rules, cfg.governor));
    }
}

contract GvInformationDeployer is GvCreate2Deployer {
    struct InformationInit {
        address token;
        address rules;
        address assembly_;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(InformationInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, InformationInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(InformationInit calldata cfg) internal pure returns (bytes memory) {
        return abi.encodePacked(type(GvInformation).creationCode, abi.encode(cfg.token, cfg.rules, cfg.assembly_));
    }
}

contract GvShareTermsDeployer is GvCreate2Deployer {
    struct TermsInit {
        address issuer;
        address token;
        address rules;
        address consideration;
        address binder;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(TermsInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, TermsInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(TermsInit calldata cfg) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(GvShareTerms).creationCode, abi.encode(cfg.issuer, cfg.token, cfg.rules, cfg.consideration, cfg.binder)
        );
    }
}

contract GvAcquisitionDeployer is GvCreate2Deployer {
    struct AcquisitionInit {
        address token;
        address rules;
        address terms;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(AcquisitionInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, AcquisitionInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(AcquisitionInit calldata cfg) internal pure returns (bytes memory) {
        return abi.encodePacked(type(GvAcquisition).creationCode, abi.encode(cfg.token, cfg.rules, cfg.terms));
    }
}

contract GvRecoveryDeployer is GvCreate2Deployer {
    struct RecoveryInit {
        address token;
        address rules;
        address terms;
        address assembly_;
        address timelock;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(RecoveryInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, RecoveryInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(RecoveryInit calldata cfg) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(GvRecovery).creationCode, abi.encode(cfg.token, cfg.rules, cfg.terms, cfg.assembly_, cfg.timelock)
        );
    }
}
