// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { IERC20 } from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import { SafeERC20 } from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import { ReentrancyGuard } from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/// @notice Pull-payment escrow for an ERC-20 consideration token. Not a custody admin.
/// Credits are balances the contract already holds. Withdraw pays the credited account, never the caller
/// unless the caller is that account.
abstract contract GvEscrow is ReentrancyGuard {
    using SafeERC20 for IERC20;

    mapping(address account => mapping(address currency => uint256 amount)) public proceeds;
    mapping(address currency => uint256 amount) public proceedsLiability;

    error ZeroValue();
    error FeeOnTransfer(address token);
    error EscrowShortfall(address token);

    event ProceedsWithdrawn(address indexed account, address indexed currency, uint256 amount);

    function withdrawProceeds(address currency) external nonReentrant {
        uint256 amount = proceeds[msg.sender][currency];
        if (amount == 0) revert ZeroValue();
        proceeds[msg.sender][currency] = 0;
        proceedsLiability[currency] -= amount;
        IERC20(currency).safeTransfer(msg.sender, amount);
        emit ProceedsWithdrawn(msg.sender, currency, amount);
    }

    function _pull(address currency, address from, uint256 amount) internal {
        if (amount == 0) revert ZeroValue();
        uint256 beforeBal = IERC20(currency).balanceOf(address(this));
        IERC20(currency).safeTransferFrom(from, address(this), amount);
        if (IERC20(currency).balanceOf(address(this)) - beforeBal != amount) revert FeeOnTransfer(currency);
    }

    function _credit(address account, address currency, uint256 amount) internal {
        if (amount == 0) return;
        if (IERC20(currency).balanceOf(address(this)) < proceedsLiability[currency] + amount) {
            revert EscrowShortfall(currency);
        }
        proceeds[account][currency] += amount;
        proceedsLiability[currency] += amount;
    }
}
