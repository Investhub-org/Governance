// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { TimelockController } from "@openzeppelin/contracts/governance/TimelockController.sol";
import {
    GvDividendDeployer,
    GvGovernorDeployer,
    GvShareDeployer,
    GvTimelockDeployer,
    GvVotesWrapperDeployer
} from "./deployers/GvDeployers.sol";

/**
 * @title GvKitFactory
 * @notice CREATE2 deployment of a share (or wrapper), an OpenZeppelin timelock, a governor, and a
 * dividend contract. The factory is not an admin of anything it deploys.
 *
 * In the same transaction it grants the governor the timelock proposer, executor, and canceller
 * roles, then renounces the temporary admin it needed to do that. OpenZeppelin's timelock also
 * grants `DEFAULT_ADMIN_ROLE` to itself. That role can be used only by scheduling a call through
 * the timelock, which the governor can do only after a vote and the delay.
 *
 * The caller of {deploy} is the issuer. The issuer receives a native share's initial supply.
 * The factory does not register a directory entry. Issuers who want a pointer call {GvDirectory}
 * themselves. Predict an address with {predict} and the same issuer, spec, and salt.
 *
 * Votes token choices:
 * - native share: this factory deploys {GvShare}
 * - existing plain ERC-20, including CMTAT v3: this factory deploys {GvVotesWrapper}
 * - existing ERC-5805 token whose `CLOCK_MODE` is timestamp: the governor uses it directly
 *
 * Set only one of `existingUnderlying` and `existingVotesToken`. Leave both at zero for a native share.
 */
interface IGvArticlesIssuer {
    function recognizeIssuer(address issuer) external;
}

contract GvKitFactory {
    enum VotesKind {
        NativeShare,
        WrappedUnderlying,
        ExistingVotes
    }

    struct ShareSpec {
        string name;
        string symbol;
        uint8 decimals;
        uint256 initialSupply;
        address existingUnderlying;
        address existingVotesToken;
    }

    struct GovSpec {
        string name;
        uint48 votingDelay;
        uint32 votingPeriod;
        uint256 proposalThreshold;
        uint256 quorumNumerator;
        uint256 timelockDelay;
    }

    struct Deployment {
        address issuer;
        address share;
        address governor;
        address timelock;
        address dividend;
        address underlying;
        VotesKind kind;
        string metadataURI;
    }

    bytes32 public constant SHARE_TAG = keccak256("gv-kit.share");
    bytes32 public constant TIMELOCK_TAG = keccak256("gv-kit.timelock");
    bytes32 public constant GOVERNOR_TAG = keccak256("gv-kit.governor");
    bytes32 public constant DIVIDEND_TAG = keccak256("gv-kit.dividend");
    string public constant KIT_VERSION = "1";

    GvShareDeployer public immutable shareDeployer;
    GvVotesWrapperDeployer public immutable wrapperDeployer;
    GvTimelockDeployer public immutable timelockDeployer;
    GvGovernorDeployer public immutable governorDeployer;
    GvDividendDeployer public immutable dividendDeployer;

    Deployment[] private _all;
    mapping(address issuer => uint256[] indexes) private _byIssuer;
    /// @dev governor => index in `_all`, plus one. Zero means unknown.
    mapping(address governor => uint256 indexPlusOne) private _byGovernor;

    error ZeroAddress();
    error EmptyString();
    error InvalidDecimals(uint8 decimals);
    error InvalidQuorum(uint256 numerator);
    error InvalidVotingDelay();
    error InvalidVotingPeriod();
    error ConflictingTokenMode();
    error ZeroSupply();
    error ThresholdExceedsSupply(uint256 threshold, uint256 supply);
    error VotesTokenUnsupported(address token);
    error ClockNotTimestamp(address token);
    error MetadataTooLong();
    error UnknownGovernor(address governor);
    error PredictedAddressMismatch();
    error DeployerNotBound(address deployer);

    event IssuerKitDeployed(
        address indexed issuer, address share, address governor, address timelock, address dividend, string metadataURI
    );
    event VotesTokenBound(address indexed governor, address indexed votesToken, address underlying, VotesKind kind);

    /// @dev The governor records the issuer in the deploy transaction. This factory is not that issuer.

    /**
     * @notice Bind deployers that were constructed with this factory's address.
     * Deploy the five deployers first, then this factory, so each initcode stays under EIP-3860.
     * The deployers are not admins. They can only be called by this factory.
     */
    constructor(
        GvShareDeployer shareDeployer_,
        GvVotesWrapperDeployer wrapperDeployer_,
        GvTimelockDeployer timelockDeployer_,
        GvGovernorDeployer governorDeployer_,
        GvDividendDeployer dividendDeployer_
    ) {
        _bind(address(shareDeployer_), shareDeployer_.factory());
        _bind(address(wrapperDeployer_), wrapperDeployer_.factory());
        _bind(address(timelockDeployer_), timelockDeployer_.factory());
        _bind(address(governorDeployer_), governorDeployer_.factory());
        _bind(address(dividendDeployer_), dividendDeployer_.factory());
        shareDeployer = shareDeployer_;
        wrapperDeployer = wrapperDeployer_;
        timelockDeployer = timelockDeployer_;
        governorDeployer = governorDeployer_;
        dividendDeployer = dividendDeployer_;
    }

    function _bind(address deployer, address claimedFactory) private view {
        if (deployer.code.length == 0 || claimedFactory != address(this)) revert DeployerNotBound(deployer);
    }

    function deploymentCount() external view returns (uint256) {
        return _all.length;
    }

    function deploymentAt(uint256 index) external view returns (Deployment memory) {
        return _all[index];
    }

    function issuerDeploymentCount(address issuer) external view returns (uint256) {
        return _byIssuer[issuer].length;
    }

    function issuerDeployment(address issuer, uint256 index) external view returns (Deployment memory) {
        return _all[_byIssuer[issuer][index]];
    }

    function deploymentByGovernor(address governor) external view returns (Deployment memory) {
        uint256 idx = _byGovernor[governor];
        if (idx == 0) revert UnknownGovernor(governor);
        return _all[idx - 1];
    }

    function derivedSalt(address issuer, bytes32 salt, bytes32 tag) public pure returns (bytes32) {
        return keccak256(abi.encode(issuer, salt, tag));
    }

    function predict(address issuer, ShareSpec calldata shareSpec, GovSpec calldata govSpec, bytes32 salt)
        external
        view
        returns (address share, address governor, address timelock, address dividend)
    {
        Plan memory plan = _plan(issuer, shareSpec, govSpec, salt);
        return (plan.share, plan.governor, plan.timelock, plan.dividend);
    }

    /**
     * @notice Deploy a kit. `msg.sender` is the issuer and, for a native share, receives the supply.
     * @param salt Issuer-chosen salt. Combined with the issuer address, so two issuers can reuse a salt.
     */
    struct Plan {
        address share;
        address governor;
        address timelock;
        address dividend;
        address underlying;
        VotesKind kind;
    }

    function deploy(ShareSpec calldata shareSpec, GovSpec calldata govSpec, string calldata metadataURI, bytes32 salt)
        external
        returns (address share, address governor, address timelock, address dividend)
    {
        if (bytes(metadataURI).length > 1024) revert MetadataTooLong();
        Plan memory plan = _plan(msg.sender, shareSpec, govSpec, salt);
        return _deploy(msg.sender, shareSpec, govSpec, metadataURI, salt, plan);
    }

    function _wireTimelock(address timelock, address governor) private {
        TimelockController tl = TimelockController(payable(timelock));
        tl.grantRole(tl.PROPOSER_ROLE(), governor);
        tl.grantRole(tl.EXECUTOR_ROLE(), governor);
        tl.grantRole(tl.CANCELLER_ROLE(), governor);
        tl.renounceRole(tl.DEFAULT_ADMIN_ROLE(), address(this));
    }

    function _plan(address issuer, ShareSpec calldata shareSpec, GovSpec calldata govSpec, bytes32 salt)
        private
        view
        returns (Plan memory plan)
    {
        _validate(issuer, shareSpec, govSpec);
        plan.kind = _kind(shareSpec);
        if (plan.kind == VotesKind.WrappedUnderlying) plan.underlying = shareSpec.existingUnderlying;
        plan.timelock = _predictTimelock(issuer, govSpec, salt);
        plan.share = _predictShare(issuer, shareSpec, salt, plan.timelock, plan.kind);
        plan.governor = _predictGovernor(issuer, govSpec, salt, plan.share, plan.timelock);
        plan.dividend = _create2(
            address(dividendDeployer), derivedSalt(issuer, salt, DIVIDEND_TAG), dividendDeployer.initCode(plan.timelock)
        );
    }

    function _deploy(
        address issuer,
        ShareSpec calldata shareSpec,
        GovSpec calldata govSpec,
        string calldata metadataURI,
        bytes32 salt,
        Plan memory plan
    ) private returns (address share, address governor, address timelock, address dividend) {
        timelock = timelockDeployer.deploy(
            derivedSalt(issuer, salt, TIMELOCK_TAG), govSpec.timelockDelay, address(this)
        );
        if (timelock != plan.timelock) revert PredictedAddressMismatch();

        share = _deployShare(issuer, shareSpec, salt, timelock, plan.kind);
        if (share != plan.share) revert PredictedAddressMismatch();

        governor = _deployGovernor(issuer, govSpec, salt, share, timelock);
        if (governor != plan.governor) revert PredictedAddressMismatch();
        IGvArticlesIssuer(governor).recognizeIssuer(issuer);

        dividend = dividendDeployer.deploy(derivedSalt(issuer, salt, DIVIDEND_TAG), timelock);
        if (dividend != plan.dividend) revert PredictedAddressMismatch();

        _wireTimelock(timelock, governor);
        _record(issuer, share, governor, timelock, dividend, plan.underlying, plan.kind, metadataURI);
    }

    function _predictTimelock(address issuer, GovSpec calldata govSpec, bytes32 salt) private view returns (address) {
        return _create2(
            address(timelockDeployer),
            derivedSalt(issuer, salt, TIMELOCK_TAG),
            timelockDeployer.initCode(govSpec.timelockDelay, address(this))
        );
    }

    function _predictShare(address issuer, ShareSpec calldata shareSpec, bytes32 salt, address timelock, VotesKind kind)
        private
        view
        returns (address)
    {
        if (kind == VotesKind.ExistingVotes) return shareSpec.existingVotesToken;
        bytes32 shareSalt = derivedSalt(issuer, salt, SHARE_TAG);
        if (kind == VotesKind.NativeShare) {
            return _create2(
                address(shareDeployer), shareSalt, shareDeployer.initCode(_shareInit(issuer, shareSpec, timelock))
            );
        }
        return
            _create2(address(wrapperDeployer), shareSalt, wrapperDeployer.initCode(_wrapperInit(shareSpec, timelock)));
    }

    function _predictGovernor(address issuer, GovSpec calldata govSpec, bytes32 salt, address share, address timelock)
        private
        view
        returns (address)
    {
        return _create2(
            address(governorDeployer),
            derivedSalt(issuer, salt, GOVERNOR_TAG),
            governorDeployer.initCode(_governorInit(govSpec, share, timelock))
        );
    }

    function _deployShare(address issuer, ShareSpec calldata shareSpec, bytes32 salt, address timelock, VotesKind kind)
        private
        returns (address)
    {
        if (kind == VotesKind.ExistingVotes) return shareSpec.existingVotesToken;
        bytes32 shareSalt = derivedSalt(issuer, salt, SHARE_TAG);
        if (kind == VotesKind.NativeShare) {
            return shareDeployer.deploy(shareSalt, _shareInit(issuer, shareSpec, timelock));
        }
        return wrapperDeployer.deploy(shareSalt, _wrapperInit(shareSpec, timelock));
    }

    function _deployGovernor(address issuer, GovSpec calldata govSpec, bytes32 salt, address share, address timelock)
        private
        returns (address)
    {
        return governorDeployer.deploy(derivedSalt(issuer, salt, GOVERNOR_TAG), _governorInit(govSpec, share, timelock));
    }

    function _shareInit(address issuer, ShareSpec calldata shareSpec, address timelock)
        private
        pure
        returns (GvShareDeployer.ShareInit memory)
    {
        return GvShareDeployer.ShareInit({
            name: shareSpec.name,
            symbol: shareSpec.symbol,
            decimals: shareSpec.decimals,
            issuer: issuer,
            initialSupply: shareSpec.initialSupply,
            timelock: timelock
        });
    }

    function _wrapperInit(ShareSpec calldata shareSpec, address timelock)
        private
        pure
        returns (GvVotesWrapperDeployer.WrapperInit memory)
    {
        return GvVotesWrapperDeployer.WrapperInit({
            underlying: shareSpec.existingUnderlying, name: shareSpec.name, symbol: shareSpec.symbol, timelock: timelock
        });
    }

    function _governorInit(GovSpec calldata govSpec, address share, address timelock)
        private
        pure
        returns (GvGovernorDeployer.GovernorInit memory)
    {
        return GvGovernorDeployer.GovernorInit({
            name: govSpec.name,
            votesToken: share,
            timelock: timelock,
            votingDelay: govSpec.votingDelay,
            votingPeriod: govSpec.votingPeriod,
            proposalThreshold: govSpec.proposalThreshold,
            quorumNumerator: govSpec.quorumNumerator
        });
    }

    function _record(
        address issuer,
        address share,
        address governor,
        address timelock,
        address dividend,
        address underlying,
        VotesKind kind,
        string calldata metadataURI
    ) private {
        _all.push(
            Deployment({
                issuer: issuer,
                share: share,
                governor: governor,
                timelock: timelock,
                dividend: dividend,
                underlying: underlying,
                kind: kind,
                metadataURI: metadataURI
            })
        );
        _byIssuer[issuer].push(_all.length - 1);
        _byGovernor[governor] = _all.length;
        emit IssuerKitDeployed(issuer, share, governor, timelock, dividend, metadataURI);
        emit VotesTokenBound(governor, share, underlying, kind);
    }

    function _validate(address issuer, ShareSpec calldata shareSpec, GovSpec calldata govSpec) private view {
        if (issuer == address(0)) revert ZeroAddress();
        if (bytes(govSpec.name).length == 0) revert EmptyString();
        if (govSpec.votingDelay < 1) revert InvalidVotingDelay();
        if (govSpec.votingPeriod < 1) revert InvalidVotingPeriod();
        if (govSpec.quorumNumerator < 1 || govSpec.quorumNumerator > 100) {
            revert InvalidQuorum(govSpec.quorumNumerator);
        }

        bool underlying = shareSpec.existingUnderlying != address(0);
        bool votes = shareSpec.existingVotesToken != address(0);
        if (underlying && votes) revert ConflictingTokenMode();

        if (votes) {
            if (shareSpec.initialSupply != 0) revert ConflictingTokenMode();
            _assertTimestampVotes(shareSpec.existingVotesToken);
            uint256 supply = _tryTotalSupply(shareSpec.existingVotesToken);
            if (supply > 0 && govSpec.proposalThreshold > supply) {
                revert ThresholdExceedsSupply(govSpec.proposalThreshold, supply);
            }
            return;
        }

        if (bytes(shareSpec.name).length == 0 || bytes(shareSpec.symbol).length == 0) revert EmptyString();

        if (underlying) {
            if (shareSpec.initialSupply != 0) revert ConflictingTokenMode();
            if (shareSpec.existingUnderlying.code.length == 0) {
                revert VotesTokenUnsupported(shareSpec.existingUnderlying);
            }
            return;
        }

        if (shareSpec.decimals > 18) revert InvalidDecimals(shareSpec.decimals);
        if (shareSpec.initialSupply == 0) revert ZeroSupply();
        if (govSpec.proposalThreshold > shareSpec.initialSupply) {
            revert ThresholdExceedsSupply(govSpec.proposalThreshold, shareSpec.initialSupply);
        }
    }

    function _kind(ShareSpec calldata shareSpec) private pure returns (VotesKind) {
        if (shareSpec.existingVotesToken != address(0)) return VotesKind.ExistingVotes;
        if (shareSpec.existingUnderlying != address(0)) return VotesKind.WrappedUnderlying;
        return VotesKind.NativeShare;
    }

    function _assertTimestampVotes(address token) private view {
        if (token.code.length == 0) revert VotesTokenUnsupported(token);
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("CLOCK_MODE()"));
        if (!ok || data.length == 0) revert VotesTokenUnsupported(token);
        string memory mode = abi.decode(data, (string));
        if (!_isTimestampMode(mode)) revert ClockNotTimestamp(token);
        (ok,) = token.staticcall(abi.encodeWithSignature("getVotes(address)", address(0)));
        if (!ok) revert VotesTokenUnsupported(token);
    }

    function _isTimestampMode(string memory mode) private pure returns (bool) {
        bytes memory m = bytes(mode);
        bytes memory prefix = bytes("mode=timestamp");
        if (m.length < prefix.length) return false;
        for (uint256 i; i < prefix.length; ++i) {
            if (m[i] != prefix[i]) return false;
        }
        return m.length == prefix.length || m[prefix.length] == bytes1("&");
    }

    function _tryTotalSupply(address token) private view returns (uint256) {
        (bool ok, bytes memory data) = token.staticcall(abi.encodeWithSignature("totalSupply()"));
        if (!ok || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    function _create2(address deployer, bytes32 salt, bytes memory bytecode) private pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, keccak256(bytecode))))));
    }
}
