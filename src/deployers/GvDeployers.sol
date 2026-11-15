// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import { GvShare } from "../GvShare.sol";
import { GvVotesWrapper } from "../GvVotesWrapper.sol";
import { GvGovernor } from "../GvGovernor.sol";
import { GvDividend } from "../GvDividend.sol";

/**
 * @notice CREATE2 helper. The factory is the only caller. A deployer holds no role on a kit.
 * `initCode` is the same bytes `deploy` passes to CREATE2, so the factory can predict the address.
 */
abstract contract GvCreate2Deployer {
    address public immutable factory;

    error OnlyFactory(address caller);
    error Create2Failed();

    constructor(address factory_) {
        if (factory_ == address(0)) revert OnlyFactory(address(0));
        factory = factory_;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert OnlyFactory(msg.sender);
        _;
    }

    function _create2(bytes memory bytecode, bytes32 salt) internal returns (address addr) {
        assembly ("memory-safe") {
            addr := create2(0, add(bytecode, 0x20), mload(bytecode), salt)
        }
        if (addr == address(0)) revert Create2Failed();
    }
}

contract GvShareDeployer is GvCreate2Deployer {
    struct ShareInit {
        string name;
        string symbol;
        uint8 decimals;
        address issuer;
        uint256 initialSupply;
        address timelock;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(ShareInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, ShareInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(ShareInit calldata cfg) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(GvShare).creationCode,
            abi.encode(cfg.name, cfg.symbol, cfg.decimals, cfg.issuer, cfg.initialSupply, cfg.timelock)
        );
    }
}

contract GvVotesWrapperDeployer is GvCreate2Deployer {
    struct WrapperInit {
        address underlying;
        string name;
        string symbol;
        address timelock;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(WrapperInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, WrapperInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(WrapperInit calldata cfg) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(GvVotesWrapper).creationCode, abi.encode(cfg.underlying, cfg.name, cfg.symbol, cfg.timelock)
        );
    }
}

contract GvTimelockDeployer is GvCreate2Deployer {
    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(uint256 minDelay, address admin) external pure returns (bytes memory) {
        return _initCode(minDelay, admin);
    }

    function deploy(bytes32 salt, uint256 minDelay, address admin) external onlyFactory returns (address) {
        return _create2(_initCode(minDelay, admin), salt);
    }

    function _initCode(uint256 minDelay, address admin) internal pure returns (bytes memory) {
        address[] memory empty = new address[](0);
        return abi.encodePacked(type(TimelockController).creationCode, abi.encode(minDelay, empty, empty, admin));
    }
}

contract GvGovernorDeployer is GvCreate2Deployer {
    struct GovernorInit {
        string name;
        address votesToken;
        address timelock;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumNumerator;
    }

    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(GovernorInit calldata cfg) external pure returns (bytes memory) {
        return _initCode(cfg);
    }

    function deploy(bytes32 salt, GovernorInit calldata cfg) external onlyFactory returns (address) {
        return _create2(_initCode(cfg), salt);
    }

    function _initCode(GovernorInit calldata cfg) internal pure returns (bytes memory) {
        return abi.encodePacked(
            type(GvGovernor).creationCode,
            abi.encode(
                cfg.name,
                cfg.votesToken,
                cfg.timelock,
                cfg.votingDelay,
                cfg.votingPeriod,
                cfg.proposalThreshold,
                cfg.quorumNumerator
            )
        );
    }
}

contract GvDividendDeployer is GvCreate2Deployer {
    constructor(address factory_) GvCreate2Deployer(factory_) { }

    function initCode(address timelock) external pure returns (bytes memory) {
        return abi.encodePacked(type(GvDividend).creationCode, abi.encode(timelock));
    }

    function deploy(bytes32 salt, address timelock) external onlyFactory returns (address) {
        return _create2(abi.encodePacked(type(GvDividend).creationCode, abi.encode(timelock)), salt);
    }
}
