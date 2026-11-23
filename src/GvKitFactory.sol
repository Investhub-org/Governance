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
import {
    GvAcquisitionDeployer,
    GvAssemblyDeployer,
    GvCompanyRulesDeployer,
    GvInformationDeployer,
    GvRecoveryDeployer,
    GvShareTermsDeployer
} from "./deployers/GvModuleDeployers.sol";

/**
 * @title GvKitFactory
 * @notice CREATE2 deployment of a share (or wrapper), an OpenZeppelin timelock, a governor, and a
 * dividend contract. {deploySet} also deploys the rule modules in that same transaction.
 * The factory is not an admin of anything it deploys.
 *
 * In the same transaction it grants the governor the timelock proposer, executor, and canceller
 * roles, then renounces the temporary admin it needed to do that. OpenZeppelin's timelock also
 * grants `DEFAULT_ADMIN_ROLE` to itself. That role can be used only by scheduling a call through
 * the timelock, which the governor can do only after a vote and the delay.
 *
 * The caller of {deploy} and {deploySet} is the issuer. The issuer receives a native share's initial supply.
 * The factory does not register a directory entry. Issuers who want a pointer call {GvDirectory}
 * themselves. Predict an address with {predict} or {predictSet} and the same issuer, spec, and salt.
 *
 * {deploySet} is the native-share path. It deploys company rules, the meeting record, the information
 * record, share terms, acquisition, and recovery, then points the governor at the meeting and the terms
 * at the acquisition. The issuer owns the three Ownable modules. The factory's one-time wiring rights
 * are cleared before the transaction returns. The share token's transfer policy and share modules stay
 * unset until the timelock sets them. Wrap mode and an existing votes token stay on {deploy}: those
 * tokens are not a {GvShare}, and the rule modules are typed to {GvShare}.
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
    function renounceArticlesWirer() external;
    function setArticlesGate(address gate) external;
}

interface IGvTermsAcquisition {
    function setAcquisition(address acquisition_) external;
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
        address rules;
        address assembly_;
        address information;
        address terms;
        address acquisition;
        address recovery;
    }

    /// @notice Addresses of one issuer set. Kit-only deploys leave the module fields at zero.
    struct Modules {
        address rules;
        address assembly_;
        address information;
        address terms;
        address acquisition;
        address recovery;
    }

    struct PredictedSet {
        address share;
        address governor;
        address timelock;
        address dividend;
        address rules;
        address assembly_;
        address information;
        address terms;
        address acquisition;
        address recovery;
    }

    bytes32 public constant SHARE_TAG = keccak256("gv-kit.share");
    bytes32 public constant TIMELOCK_TAG = keccak256("gv-kit.timelock");
    bytes32 public constant GOVERNOR_TAG = keccak256("gv-kit.governor");
    bytes32 public constant DIVIDEND_TAG = keccak256("gv-kit.dividend");
    bytes32 public constant RULES_TAG = keccak256("gv-kit.rules");
    bytes32 public constant ASSEMBLY_TAG = keccak256("gv-kit.assembly");
    bytes32 public constant INFORMATION_TAG = keccak256("gv-kit.information");
    bytes32 public constant TERMS_TAG = keccak256("gv-kit.terms");
    bytes32 public constant ACQUISITION_TAG = keccak256("gv-kit.acquisition");
    bytes32 public constant RECOVERY_TAG = keccak256("gv-kit.recovery");
    string public constant KIT_VERSION = "2";

    GvShareDeployer public immutable shareDeployer;
    GvVotesWrapperDeployer public immutable wrapperDeployer;
    GvTimelockDeployer public immutable timelockDeployer;
    GvGovernorDeployer public immutable governorDeployer;
    GvDividendDeployer public immutable dividendDeployer;
    GvCompanyRulesDeployer public immutable rulesDeployer;
    GvAssemblyDeployer public immutable assemblyDeployer;
    GvInformationDeployer public immutable informationDeployer;
    GvShareTermsDeployer public immutable termsDeployer;
    GvAcquisitionDeployer public immutable acquisitionDeployer;
    GvRecoveryDeployer public immutable recoveryDeployer;

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
    error ModulesNeedNativeShare();
    error ConsiderationUnset();

    event IssuerKitDeployed(
        address indexed issuer, address share, address governor, address timelock, address dividend, string metadataURI
    );
    event IssuerSetDeployed(
        address indexed issuer,
        address rules,
        address assembly_,
        address information,
        address terms,
        address acquisition,
        address recovery
    );
    event VotesTokenBound(address indexed governor, address indexed votesToken, address underlying, VotesKind kind);

    /// @dev The governor records the issuer in the deploy transaction. This factory is not that issuer.

    /**
     * @notice Bind deployers that were constructed with this factory's address.
     * Deploy the eleven deployers first, then this factory, so each initcode stays under EIP-3860.
     * The deployers are not admins. They can only be called by this factory.
     */
    constructor(
        GvShareDeployer shareDeployer_,
        GvVotesWrapperDeployer wrapperDeployer_,
        GvTimelockDeployer timelockDeployer_,
        GvGovernorDeployer governorDeployer_,
        GvDividendDeployer dividendDeployer_,
        GvCompanyRulesDeployer rulesDeployer_,
        GvAssemblyDeployer assemblyDeployer_,
        GvInformationDeployer informationDeployer_,
        GvShareTermsDeployer termsDeployer_,
        GvAcquisitionDeployer acquisitionDeployer_,
        GvRecoveryDeployer recoveryDeployer_
    ) {
        _bind(address(shareDeployer_), shareDeployer_.factory());
        _bind(address(wrapperDeployer_), wrapperDeployer_.factory());
        _bind(address(timelockDeployer_), timelockDeployer_.factory());
        _bind(address(governorDeployer_), governorDeployer_.factory());
        _bind(address(dividendDeployer_), dividendDeployer_.factory());
        _bind(address(rulesDeployer_), rulesDeployer_.factory());
        _bind(address(assemblyDeployer_), assemblyDeployer_.factory());
        _bind(address(informationDeployer_), informationDeployer_.factory());
        _bind(address(termsDeployer_), termsDeployer_.factory());
        _bind(address(acquisitionDeployer_), acquisitionDeployer_.factory());
        _bind(address(recoveryDeployer_), recoveryDeployer_.factory());
        shareDeployer = shareDeployer_;
        wrapperDeployer = wrapperDeployer_;
        timelockDeployer = timelockDeployer_;
        governorDeployer = governorDeployer_;
        dividendDeployer = dividendDeployer_;
        rulesDeployer = rulesDeployer_;
        assemblyDeployer = assemblyDeployer_;
        informationDeployer = informationDeployer_;
        termsDeployer = termsDeployer_;
        acquisitionDeployer = acquisitionDeployer_;
        recoveryDeployer = recoveryDeployer_;
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
        _deployKit(msg.sender, shareSpec, govSpec, salt, plan);
        IGvArticlesIssuer(plan.governor).renounceArticlesWirer();
        _record(msg.sender, plan, metadataURI, _emptyModules());
        return (plan.share, plan.governor, plan.timelock, plan.dividend);
    }

    /**
     * @notice Deploy a native share, the ballot, the dividend, and the rule modules. `msg.sender` is the issuer.
     * @param consideration ERC-20 used to escrow a sale. It must already have code. The factory does not deploy it.
     * @param salt Issuer-chosen salt. Combined with the issuer address, so two issuers can reuse a salt.
     */
    function predictSet(
        address issuer,
        ShareSpec calldata shareSpec,
        GovSpec calldata govSpec,
        address consideration,
        bytes32 salt
    ) external view returns (PredictedSet memory predicted) {
        _requireNativeSet(shareSpec, consideration);
        Plan memory plan = _plan(issuer, shareSpec, govSpec, salt);
        Modules memory modules = _planModules(issuer, plan.share, plan.governor, plan.timelock, consideration, salt);
        return _predicted(plan, modules);
    }

    function deploySet(
        ShareSpec calldata shareSpec,
        GovSpec calldata govSpec,
        string calldata metadataURI,
        address consideration,
        bytes32 salt
    ) external returns (PredictedSet memory deployed) {
        if (bytes(metadataURI).length > 1024) revert MetadataTooLong();
        _requireNativeSet(shareSpec, consideration);
        return _deploySet(msg.sender, shareSpec, govSpec, metadataURI, consideration, salt);
    }

    function _deploySet(
        address issuer,
        ShareSpec calldata shareSpec,
        GovSpec calldata govSpec,
        string calldata metadataURI,
        address consideration,
        bytes32 salt
    ) private returns (PredictedSet memory deployed) {
        Plan memory plan = _plan(issuer, shareSpec, govSpec, salt);
        Modules memory modules = _planModules(issuer, plan.share, plan.governor, plan.timelock, consideration, salt);
        _deployKit(issuer, shareSpec, govSpec, salt, plan);
        _createModules(issuer, plan.share, plan.governor, plan.timelock, consideration, salt, modules);
        _wireSet(plan.governor, modules);
        _record(issuer, plan, metadataURI, modules);
        deployed = _predicted(plan, modules);
    }

    function _wireSet(address governor, Modules memory modules) private {
        IGvArticlesIssuer(governor).setArticlesGate(modules.assembly_);
        IGvTermsAcquisition(modules.terms).setAcquisition(modules.acquisition);
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

    function _deployKit(
        address issuer,
        ShareSpec calldata shareSpec,
        GovSpec calldata govSpec,
        bytes32 salt,
        Plan memory plan
    ) private {
        address timelock = timelockDeployer.deploy(
            derivedSalt(issuer, salt, TIMELOCK_TAG), govSpec.timelockDelay, address(this)
        );
        if (timelock != plan.timelock) revert PredictedAddressMismatch();

        address share = _deployShare(issuer, shareSpec, salt, timelock, plan.kind);
        if (share != plan.share) revert PredictedAddressMismatch();

        address governor = _deployGovernor(issuer, govSpec, salt, share, timelock);
        if (governor != plan.governor) revert PredictedAddressMismatch();
        IGvArticlesIssuer(governor).recognizeIssuer(issuer);

        address dividend = dividendDeployer.deploy(derivedSalt(issuer, salt, DIVIDEND_TAG), timelock);
        if (dividend != plan.dividend) revert PredictedAddressMismatch();

        _wireTimelock(timelock, governor);
    }

    function _requireNativeSet(ShareSpec calldata shareSpec, address consideration) private view {
        if (_kind(shareSpec) != VotesKind.NativeShare) revert ModulesNeedNativeShare();
        if (consideration.code.length == 0) revert ConsiderationUnset();
    }

    function _emptyModules() private pure returns (Modules memory) { }

    function _predicted(Plan memory plan, Modules memory modules) private pure returns (PredictedSet memory) {
        return PredictedSet({
            share: plan.share,
            governor: plan.governor,
            timelock: plan.timelock,
            dividend: plan.dividend,
            rules: modules.rules,
            assembly_: modules.assembly_,
            information: modules.information,
            terms: modules.terms,
            acquisition: modules.acquisition,
            recovery: modules.recovery
        });
    }

    function _planModules(
        address issuer,
        address share,
        address governor,
        address timelock,
        address consideration,
        bytes32 salt
    ) private view returns (Modules memory modules) {
        modules.rules = _create2(
            address(rulesDeployer), derivedSalt(issuer, salt, RULES_TAG), rulesDeployer.initCode(issuer)
        );
        modules.assembly_ = _create2(
            address(assemblyDeployer),
            derivedSalt(issuer, salt, ASSEMBLY_TAG),
            assemblyDeployer.initCode(_assemblyInit(issuer, share, modules.rules, governor))
        );
        modules.information = _create2(
            address(informationDeployer),
            derivedSalt(issuer, salt, INFORMATION_TAG),
            informationDeployer.initCode(_informationInit(share, modules.rules, modules.assembly_))
        );
        modules.terms = _create2(
            address(termsDeployer),
            derivedSalt(issuer, salt, TERMS_TAG),
            termsDeployer.initCode(_termsInit(issuer, share, modules.rules, consideration))
        );
        modules.acquisition = _create2(
            address(acquisitionDeployer),
            derivedSalt(issuer, salt, ACQUISITION_TAG),
            acquisitionDeployer.initCode(_acquisitionInit(share, modules.rules, modules.terms))
        );
        modules.recovery = _create2(
            address(recoveryDeployer),
            derivedSalt(issuer, salt, RECOVERY_TAG),
            recoveryDeployer.initCode(_recoveryInit(share, modules.rules, modules.terms, modules.assembly_, timelock))
        );
    }

    function _createModules(
        address issuer,
        address share,
        address governor,
        address timelock,
        address consideration,
        bytes32 salt,
        Modules memory modules
    ) private {
        _must(rulesDeployer.deploy(derivedSalt(issuer, salt, RULES_TAG), issuer), modules.rules);
        _must(
            assemblyDeployer.deploy(
                derivedSalt(issuer, salt, ASSEMBLY_TAG), _assemblyInit(issuer, share, modules.rules, governor)
            ),
            modules.assembly_
        );
        _must(
            informationDeployer.deploy(
                derivedSalt(issuer, salt, INFORMATION_TAG), _informationInit(share, modules.rules, modules.assembly_)
            ),
            modules.information
        );
        _must(
            termsDeployer.deploy(
                derivedSalt(issuer, salt, TERMS_TAG), _termsInit(issuer, share, modules.rules, consideration)
            ),
            modules.terms
        );
        _must(
            acquisitionDeployer.deploy(
                derivedSalt(issuer, salt, ACQUISITION_TAG), _acquisitionInit(share, modules.rules, modules.terms)
            ),
            modules.acquisition
        );
        _must(
            recoveryDeployer.deploy(
                derivedSalt(issuer, salt, RECOVERY_TAG),
                _recoveryInit(share, modules.rules, modules.terms, modules.assembly_, timelock)
            ),
            modules.recovery
        );
    }

    function _must(address got, address want) private pure {
        if (got != want) revert PredictedAddressMismatch();
    }

    function _assemblyInit(address issuer, address share, address rules, address governor)
        private
        pure
        returns (GvAssemblyDeployer.AssemblyInit memory)
    {
        return GvAssemblyDeployer.AssemblyInit({ issuer: issuer, token: share, rules: rules, governor: governor });
    }

    function _informationInit(address share, address rules, address assembly_)
        private
        pure
        returns (GvInformationDeployer.InformationInit memory)
    {
        return GvInformationDeployer.InformationInit({ token: share, rules: rules, assembly_: assembly_ });
    }

    function _termsInit(address issuer, address share, address rules, address consideration)
        private
        view
        returns (GvShareTermsDeployer.TermsInit memory)
    {
        return GvShareTermsDeployer.TermsInit({
            issuer: issuer, token: share, rules: rules, consideration: consideration, binder: address(this)
        });
    }

    function _acquisitionInit(address share, address rules, address terms)
        private
        pure
        returns (GvAcquisitionDeployer.AcquisitionInit memory)
    {
        return GvAcquisitionDeployer.AcquisitionInit({ token: share, rules: rules, terms: terms });
    }

    function _recoveryInit(address share, address rules, address terms, address assembly_, address timelock)
        private
        pure
        returns (GvRecoveryDeployer.RecoveryInit memory)
    {
        return GvRecoveryDeployer.RecoveryInit({
            token: share, rules: rules, terms: terms, assembly_: assembly_, timelock: timelock
        });
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

    function _record(address issuer, Plan memory plan, string calldata metadataURI, Modules memory modules) private {
        _all.push(
            Deployment({
                issuer: issuer,
                share: plan.share,
                governor: plan.governor,
                timelock: plan.timelock,
                dividend: plan.dividend,
                underlying: plan.underlying,
                kind: plan.kind,
                metadataURI: metadataURI,
                rules: modules.rules,
                assembly_: modules.assembly_,
                information: modules.information,
                terms: modules.terms,
                acquisition: modules.acquisition,
                recovery: modules.recovery
            })
        );
        _byIssuer[issuer].push(_all.length - 1);
        _byGovernor[plan.governor] = _all.length;
        emit IssuerKitDeployed(issuer, plan.share, plan.governor, plan.timelock, plan.dividend, metadataURI);
        emit VotesTokenBound(plan.governor, plan.share, plan.underlying, plan.kind);
        if (modules.rules != address(0)) {
            emit IssuerSetDeployed(
                issuer,
                modules.rules,
                modules.assembly_,
                modules.information,
                modules.terms,
                modules.acquisition,
                modules.recovery
            );
        }
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
