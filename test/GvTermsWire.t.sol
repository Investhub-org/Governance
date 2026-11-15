// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { GvCompanyRules } from "../src/GvCompanyRules.sol";
import { GvGovernor } from "../src/GvGovernor.sol";
import { GvShare } from "../src/GvShare.sol";
import { GvShareTerms } from "../src/GvShareTerms.sol";
import { KitFixture } from "./KitFixture.sol";
import { MockERC20 } from "./mocks/MockERC20.sol";

/// @notice The kit timelock is the only address that can arm the share policy. The factory stays role-less.
contract GvTermsWireTest is KitFixture {
    address internal issuer = makeAddr("issuer");
    address internal holder = makeAddr("holder");
    address internal stranger = makeAddr("stranger");

    function test_policy_is_bound_by_the_timelock_and_not_by_a_stranger() public {
        (address shareAddr, GvGovernor governor,,) =
            _deploy(issuer, _nativeSpec(100), _govSpec(1, 4), bytes32(uint256(9)));
        GvShare share = GvShare(shareAddr);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        GvCompanyRules rules = new GvCompanyRules(address(this));
        GvShareTerms terms = new GvShareTerms(address(this), share, rules, address(usdc));

        vm.prank(stranger);
        vm.expectPartialRevert(GvShare.OnlyTimelock.selector);
        share.setTransferPolicy(address(terms));
        vm.prank(stranger);
        vm.expectPartialRevert(GvShare.NotShareModule.selector);
        share.moduleTransfer(issuer, holder, 1);

        _delegate(shareAddr, issuer);
        address[] memory targets = new address[](1);
        targets[0] = shareAddr;
        bytes[] memory calldatas = new bytes[](1);
        calldatas[0] = abi.encodeCall(GvShare.setTransferPolicy, (address(terms)));
        _pass(governor, issuer, targets, calldatas, "Bind the share terms");
        assertEq(share.transferPolicy(), address(terms));
        assertEq(terms.owner(), address(this));

        terms.publishSha(keccak256("sha-v1"), "bafybeiplaceholder");
        terms.setWhitelist(issuer, true);
        terms.setWhitelist(holder, true);
        terms.setPreEmptionEnabled(false);
        vm.prank(holder);
        terms.acceptSha();
        vm.prank(issuer);
        share.transfer(holder, 1);
        assertEq(share.balanceOf(holder), 1);

        terms.publishSha(keccak256("sha-v2"), "bafybeinext");
        vm.prank(issuer);
        vm.expectPartialRevert(GvShareTerms.ShaNotAccepted.selector);
        share.transfer(holder, 1);
    }
}
