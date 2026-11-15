// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { ERC20Wrapper } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Wrapper.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title GvVotesWrapper
 * @notice Ownerless ERC-20 wrapper that gives an existing token an ERC-5805 timestamp clock.
 *
 * CMTAT v3 is an ERC-20 equity token. It does not implement ERC-5805 (`IVotes`), so OpenZeppelin
 * Governor cannot read it directly. Holders deposit the CMTAT (or any plain ERC-20) and receive
 * wrapper units 1:1. Those units are the votes token. Withdrawing burns the wrapper and returns
 * the underlying. Nobody can mint wrapper units except through a deposit, plus {recover} for
 * tokens that were transferred in by mistake, and {recover} is only the kit timelock.
 *
 * The wrapper does not take the CMTAT admin, minter, pauser, or rule-engine roles. Those stay on
 * the issuer's own token. A frozen or non-whitelisted CMTAT account simply cannot deposit.
 *
 * Delegation is opt-in, as on {GvShare}. Dividends on the legal register are a separate question:
 * build the merkle tree from the underlying holders, and expand this contract's underlying balance
 * into the wrapper holders so the same share is not paid twice.
 */
contract GvVotesWrapper is ERC20, ERC20Permit, ERC20Votes, ERC20Wrapper {
    address public immutable timelock;

    error OnlyTimelock(address caller);
    error ZeroAddress();
    error EmptyString();

    constructor(IERC20 underlying_, string memory name_, string memory symbol_, address timelock_)
        ERC20(name_, symbol_)
        ERC20Permit(name_)
        ERC20Wrapper(underlying_)
    {
        if (address(underlying_) == address(0) || timelock_ == address(0)) revert ZeroAddress();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyString();
        timelock = timelock_;
    }

    /// @notice Mint wrapper units for underlying tokens that were sent here directly. Timelock only.
    function recover(address account) external returns (uint256) {
        if (msg.sender != timelock) revert OnlyTimelock(msg.sender);
        if (account == address(0)) revert ZeroAddress();
        return _recover(account);
    }

    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function decimals() public view override(ERC20, ERC20Wrapper) returns (uint8) {
        return super.decimals();
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
