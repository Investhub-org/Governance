// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import { Ownable } from "@openzeppelin/contracts/access/Ownable.sol";
import { Test } from "forge-std/Test.sol";
import { GvCompanyRules } from "../src/GvCompanyRules.sol";

/// @notice The stored defaults are placeholders. These tests check the wiring, not Liechtenstein law.
contract GvCompanyRulesTest is Test {
    GvCompanyRules internal rules;
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        rules = new GvCompanyRules(address(this));
    }

    function test_defaults_are_the_named_placeholders() public view {
        GvCompanyRules.ClassRule memory ordinary = rules.classRule(GvCompanyRules.ResolutionClass.Ordinary);
        GvCompanyRules.ClassRule memory qualified = rules.classRule(GvCompanyRules.ResolutionClass.Qualified);
        assertEq(ordinary.quorumBps, rules.PLACEHOLDER_ORDINARY_QUORUM_BPS());
        assertEq(ordinary.majorityBps, rules.PLACEHOLDER_ORDINARY_MAJORITY_BPS());
        assertEq(qualified.quorumBps, rules.PLACEHOLDER_QUALIFIED_QUORUM_BPS());
        assertEq(qualified.majorityBps, rules.PLACEHOLDER_QUALIFIED_MAJORITY_BPS());
        assertEq(rules.noticePeriod(GvCompanyRules.MeetingType.AGM), rules.PLACEHOLDER_AGM_NOTICE());
        assertEq(rules.noticePeriod(GvCompanyRules.MeetingType.EGM), rules.PLACEHOLDER_EGM_NOTICE());
        assertEq(rules.meetingCallThresholdBps(), rules.PLACEHOLDER_MEETING_CALL_BPS());
        assertEq(rules.floorDirectors(), rules.PLACEHOLDER_MIN_DIRECTORS());
        assertEq(rules.dragQuorumBps(), rules.PLACEHOLDER_DRAG_QUORUM_BPS());
        assertEq(rules.tagThresholdBps(), rules.PLACEHOLDER_TAG_THRESHOLD_BPS());
        assertEq(rules.preEmptionWindow(), rules.PLACEHOLDER_PREEMPTION_WINDOW());
        assertEq(rules.responseWindow(), rules.PLACEHOLDER_RESPONSE_WINDOW());
        assertEq(rules.recoveryDelay(), rules.PLACEHOLDER_RECOVERY_DELAY());
        assertEq(rules.recoverySignatures(), rules.PLACEHOLDER_RECOVERY_SIGNATURES());
        assertEq(rules.shareCapital(), 0);
        assertEq(rules.currencyCode(), bytes32("UNSET"));
        assertEq(rules.bandCount(), 0);
        assertEq(rules.requiredDirectors(), 1);
    }

    function test_stranger_cannot_retune_rules() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        rules.setDragQuorum(8000);
    }

    function test_recovery_delay_cannot_be_switched_off() public {
        vm.expectRevert(abi.encodeWithSelector(GvCompanyRules.DelayBelowFloor.selector, uint64(1 days)));
        rules.setRecoveryDelay(1 days);
        rules.setRecoveryDelay(rules.MIN_RECOVERY_DELAY());
        assertEq(rules.recoveryDelay(), rules.MIN_RECOVERY_DELAY());
    }

    function test_unreachable_majority_is_rejected() public {
        vm.expectRevert(abi.encodeWithSelector(GvCompanyRules.MajorityUnreachable.selector, uint16(10_000)));
        rules.setClassRule(GvCompanyRules.ResolutionClass.Ordinary, 1, 10_000);
    }

    /// @dev A configured band. The figure is an illustration of the parameter, not a PGR rule.
    function test_capital_band_raises_the_director_floor_only_when_capital_meets_it() public {
        GvCompanyRules.CapitalBand[] memory bands = new GvCompanyRules.CapitalBand[](1);
        bands[0] = GvCompanyRules.CapitalBand({ capitalAtOrAbove: 1_000_000, minDirectors: 3 });
        rules.setCapitalBands(bands);
        rules.setShareCapital(1_000_000, "CHF");
        assertEq(rules.requiredDirectors(), 3);
        assertEq(rules.currencyCode(), bytes32("CHF"));

        rules.setShareCapital(999_999, "CHF");
        assertEq(rules.requiredDirectors(), rules.floorDirectors());
    }

    function test_majority_is_strict_and_quorum_rounds_up() public view {
        assertTrue(rules.majorityMet(51, 49, 5000));
        assertFalse(rules.majorityMet(50, 50, 5000));
        assertFalse(rules.majorityMet(60, 40, 6666));
        assertTrue(rules.majorityMet(67, 33, 6666));
        assertTrue(rules.quorumMet(1, 100, 1));
        assertFalse(rules.quorumMet(0, 100, 1));
        assertTrue(rules.meetsShareThreshold(10, 100, 1000));
        assertFalse(rules.meetsShareThreshold(9, 100, 1000));
    }
}
