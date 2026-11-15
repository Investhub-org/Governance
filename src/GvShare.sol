// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { ERC20 } from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import { ERC20Permit } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Permit.sol";
import { ERC20Votes } from "@openzeppelin/contracts/token/ERC20/extensions/ERC20Votes.sol";
import { Nonces } from "@openzeppelin/contracts/utils/Nonces.sol";

/**
 * @title GvShare
 * @notice Fixed-clock share token for an issuer-owned general meeting.
 * ERC-20 + ERC-20 Permit + ERC-20 Votes, with an ERC-6372 timestamp clock.
 * The initial supply is minted to the issuer. Later minting is only the kit timelock,
 * which can act only after a successful proposal. There is no owner and no other admin.
 *
 * Holders must call {delegate} (to themselves, or to a representative) before their
 * balance counts as votes. A transfer moves voting units only for accounts that have delegated.
 *
 * This contract is not a CMTAT. A CMTAT v3 token does not implement ERC-5805. Use
 * {GvVotesWrapper} around that token, or pass an existing timestamp votes token into the factory.
 */
contract GvShare is ERC20, ERC20Permit, ERC20Votes {
    address public immutable timelock;

    uint8 private immutable _decimals;

    error OnlyTimelock(address caller);
    error ZeroAddress();
    error EmptyString();
    error InvalidDecimals(uint8 decimals);

    /**
     * @param issuer Receives `initialSupply`. This is the issuer's own wallet or multisig.
     * @param timelock_ Kit timelock. The only address that can mint later.
     * @param decimals_ Share precision. Equity registers often use 0. Maximum 18.
     */
    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_,
        address issuer,
        uint256 initialSupply,
        address timelock_
    ) ERC20(name_, symbol_) ERC20Permit(name_) {
        if (issuer == address(0) || timelock_ == address(0)) revert ZeroAddress();
        if (bytes(name_).length == 0 || bytes(symbol_).length == 0) revert EmptyString();
        if (decimals_ > 18) revert InvalidDecimals(decimals_);
        timelock = timelock_;
        _decimals = decimals_;
        if (initialSupply > 0) {
            _mint(issuer, initialSupply);
        }
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    /// @notice Capital increase. Callable only by the kit timelock, so only an executed proposal can mint.
    function mint(address to, uint256 amount) external {
        if (msg.sender != timelock) revert OnlyTimelock(msg.sender);
        _mint(to, amount);
    }

    /// @dev ERC-6372 timestamp clock. Voting delay and period are seconds.
    function clock() public view override returns (uint48) {
        return uint48(block.timestamp);
    }

    /// @dev Must match {clock}. OpenZeppelin Governor reads this from the votes token.
    // solhint-disable-next-line func-name-mixedcase
    function CLOCK_MODE() public pure override returns (string memory) {
        return "mode=timestamp";
    }

    function _update(address from, address to, uint256 value) internal override(ERC20, ERC20Votes) {
        super._update(from, to, value);
    }

    function nonces(address owner) public view override(ERC20Permit, Nonces) returns (uint256) {
        return super.nonces(owner);
    }
}
