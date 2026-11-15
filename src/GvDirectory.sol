// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title GvDirectory
 * @notice Optional, ownerless pointer list. An issuer registers the contracts for their own kit.
 * The issuer address, and the timelock stored on that entry, are the only addresses that can
 * change it. There is no admin, no upgrade, and no role for anyone else.
 *
 * The kit does not read this contract. A general meeting runs from the governor whether or not
 * anybody registered. An entry is a claim by the key that registered it. It is not proof that
 * {GvKitFactory} deployed those contracts. Read the factory's `IssuerKitDeployed` event for that.
 */
contract GvDirectory {
    struct Entry {
        address share;
        address governor;
        address timelock;
        address dividend;
        string metadataURI;
    }

    mapping(address issuer => Entry) private _entries;
    mapping(address issuer => bool) public registered;

    error AlreadyRegistered(address issuer);
    error NotRegistered(address issuer);
    error NotIssuerOrTimelock(address caller, address issuer);
    error ZeroAddress();

    event IssuerRegistered(
        address indexed issuer, address share, address governor, address timelock, address dividend, string metadataURI
    );
    event IssuerUpdated(
        address indexed issuer, address share, address governor, address timelock, address dividend, string metadataURI
    );

    function register(address share, address governor, address timelock, address dividend, string calldata metadataURI)
        external
    {
        if (registered[msg.sender]) revert AlreadyRegistered(msg.sender);
        _validate(share, governor, timelock, dividend);
        _write(msg.sender, share, governor, timelock, dividend, metadataURI);
        emit IssuerRegistered(msg.sender, share, governor, timelock, dividend, metadataURI);
    }

    /// @param issuer The address that called {register}. The caller must be that issuer or its current timelock.
    function update(
        address issuer,
        address share,
        address governor,
        address timelock,
        address dividend,
        string calldata metadataURI
    ) external {
        if (!registered[issuer]) revert NotRegistered(issuer);
        Entry storage current = _entries[issuer];
        if (msg.sender != issuer && msg.sender != current.timelock) {
            revert NotIssuerOrTimelock(msg.sender, issuer);
        }
        _validate(share, governor, timelock, dividend);
        _write(issuer, share, governor, timelock, dividend, metadataURI);
        emit IssuerUpdated(issuer, share, governor, timelock, dividend, metadataURI);
    }

    function get(address issuer) external view returns (Entry memory) {
        return _entries[issuer];
    }

    function _validate(address share, address governor, address timelock, address dividend) private pure {
        if (share == address(0) || governor == address(0) || timelock == address(0) || dividend == address(0)) {
            revert ZeroAddress();
        }
    }

    function _write(
        address issuer,
        address share,
        address governor,
        address timelock,
        address dividend,
        string calldata metadataURI
    ) private {
        Entry storage entry = _entries[issuer];
        entry.share = share;
        entry.governor = governor;
        entry.timelock = timelock;
        entry.dividend = dividend;
        entry.metadataURI = metadataURI;
        registered[issuer] = true;
    }
}
