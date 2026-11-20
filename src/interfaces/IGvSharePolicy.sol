// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Called by {GvShare} on every ordinary mint and transfer when a policy is set.
interface IGvSharePolicy {
    function authorizeTransfer(address from, address to, uint256 amount) external view;
}

/// @notice A module the timelock has bound to {GvShare.moduleTransfer}.
/// The token asks the module, in the same call, whether this exact transfer is one the module
/// is currently executing. A module that returns true for an arbitrary transfer would be a backdoor.
/// The acquisition and recovery contracts return true only for the transfer their own function just armed.
interface IGvShareModule {
    function mayForceTransfer(address from, address to, uint256 amount) external view returns (bool);
}

/// @notice Narrow view the share terms use to recognise a sale the acquisition contract itself is settling.
interface IGvTransferPermit {
    function permitsTransfer(address from, address to, uint256 amount) external view returns (bool);

    /// @dev True while a drag or tag sale is open and ordinary peer transfers must wait.
    function blocksPeerTransfers() external view returns (bool);
}
