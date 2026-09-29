// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Guilds} from "../src/Guilds.sol";
import {Diplomacy} from "../src/Diplomacy.sol";

contract RevisionTest is PactsBase {
    function test_predictedFutureHolderCannotBeProposed() public {
        uint256 gA = found(alice, "Alpha");
        uint256 gB = found(bob, "Beta");
        buy(alice, 3);
        uint256 beforeCount = guilds.proposalCount();
        vm.prank(alice);
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Attack, address(realm), 0, 7, gB, 3);
        assertEq(guilds.proposalCount(), beforeCount);
        assertEq(realm.reserveOf(gA), 3);

        // The same holder is valid only once Beta actually takes the tile.
        capture(bob, 7, 1);
        uint256 pid = proposeAttack(alice, 7, gB, 3);
        assertEq(guilds.getProposal(pid).data2, gB);
        realm.declareAttack(pid);
        assertTrue(guilds.getProposal(pid).executed);
        assertEq(realm.reserveOf(gA), 0);
    }

    function test_pactRejectsCounterBondBelowMinimumInEitherOrder() public {
        (uint256 gA, uint256 gB) = _fundTwoGuilds();
        uint256 a = _pact(alice, gB, 1000e18, 1000e18);
        uint256 b = _pact(bob, gA, 1, 0);
        vm.prank(outsider);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(a, b);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(b, a);
        _assertUnconsumed(a, b, gA, gB);
    }

    function test_pactChecksBothMinimaBeforeMovingFunds() public {
        (uint256 gA, uint256 gB) = _fundTwoGuilds();
        uint256 a = _pact(alice, gB, 20e18, 10e18);
        // Beta meets Alpha's minimum, but Alpha misses Beta's minimum by one wei.
        uint256 b = _pact(bob, gA, 10e18, 20e18 + 1);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(a, b);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(b, a);
        _assertUnconsumed(a, b, gA, gB);
    }

    function test_pactAcceptsUnequalBondsAtBothMinimaAndReturnsThem() public {
        (uint256 gA, uint256 gB) = _fundTwoGuilds();
        uint256 a = _pact(alice, gB, 20e18, 10e18);
        uint256 b = _pact(bob, gA, 10e18, 20e18);
        vm.prank(outsider);
        uint256 pact = diplomacy.sign(a, b);
        assertEq(diplomacy.getPact(pact).bondA, 20e18);
        assertEq(diplomacy.getPact(pact).bondB, 10e18);
        assertEq(guilds.treasuryOf(gA), 980e18);
        assertEq(guilds.treasuryOf(gB), 990e18);
        assertEq(token.balanceOf(address(diplomacy)), 30e18);
        warpToEpoch(10);
        diplomacy.expire(pact);
        assertEq(guilds.treasuryOf(gA), 1000e18);
        assertEq(guilds.treasuryOf(gB), 1000e18);
        assertEq(token.balanceOf(address(diplomacy)), 0);
    }

    function test_pactExplicitZeroMinimumAllowsOneWeiCounterBond() public {
        (uint256 gA, uint256 gB) = _fundTwoGuilds();
        uint256 a = _pact(alice, gB, 1000e18, 0);
        uint256 b = _pact(bob, gA, 1, 1000e18);
        uint256 pact = diplomacy.sign(a, b);
        assertEq(diplomacy.getPact(pact).bondA, 1000e18);
        assertEq(diplomacy.getPact(pact).bondB, 1);
    }

    /// @dev A failed signature must leave the other guild's approval available for a new offer.
    /// forge-config: default.fuzz.runs = 512
    function testFuzz_shortBondCanBeReplacedWithoutConsumingTheOtherApproval(
        uint256 bondSeedA,
        uint256 bondSeedB,
        bool shortA,
        bool reverse
    ) public {
        (uint256 gA, uint256 gB) = _fundTwoGuilds();
        uint256 bondA = bound(bondSeedA, 1, 1000e18 - 1);
        uint256 bondB = bound(bondSeedB, 1, 1000e18 - 1);
        uint256 minimumA = bondB + (shortA ? 0 : 1);
        uint256 minimumB = bondA + (shortA ? 1 : 0);
        uint256 a = _pact(alice, gB, bondA, minimumA);
        uint256 b = _pact(bob, gA, bondB, minimumB);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(a, b);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(b, a);
        _assertUnconsumed(a, b, gA, gB);

        uint256 rejected = shortA ? a : b;
        if (shortA) {
            bondA += 1;
            a = _pact(alice, gB, bondA, minimumA);
        } else {
            bondB += 1;
            b = _pact(bob, gA, bondB, minimumB);
        }
        vm.prank(outsider);
        uint256 id = reverse ? diplomacy.sign(b, a) : diplomacy.sign(a, b);
        Diplomacy.Pact memory p = diplomacy.getPact(id);
        assertEq(p.guildA, reverse ? gB : gA);
        assertEq(p.guildB, reverse ? gA : gB);
        assertEq(p.bondA, reverse ? bondB : bondA);
        assertEq(p.bondB, reverse ? bondA : bondB);
        assertTrue(guilds.getProposal(a).executed);
        assertTrue(guilds.getProposal(b).executed);
        assertFalse(guilds.getProposal(rejected).executed);
        assertEq(guilds.treasuryOf(gA), 1000e18 - bondA);
        assertEq(guilds.treasuryOf(gB), 1000e18 - bondB);
        assertEq(token.balanceOf(address(diplomacy)), bondA + bondB);
        warpToEpoch(10);
        diplomacy.expire(id);
        assertEq(guilds.treasuryOf(gA), 1000e18);
        assertEq(guilds.treasuryOf(gB), 1000e18);
        assertEq(token.balanceOf(address(diplomacy)), 0);
    }

    function test_maximumMinimumCannotBeSatisfiedByOneWeiBonds() public {
        (uint256 gA, uint256 gB) = _fundTwoGuilds();
        uint256 a = _pact(alice, gB, 1, type(uint256).max);
        uint256 b = _pact(bob, gA, 1, 0);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(a, b);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(b, a);
        _assertUnconsumed(a, b, gA, gB);
    }

    function _fundTwoGuilds() internal returns (uint256 gA, uint256 gB) {
        gA = found(alice, "Alpha");
        gB = found(bob, "Beta");
        vm.prank(alice);
        guilds.deposit(gA, 1000e18);
        vm.prank(bob);
        guilds.deposit(gB, 1000e18);
    }

    function _pact(address member, uint256 other, uint256 bond, uint256 minimum) internal returns (uint256) {
        vm.prank(member);
        return guilds.propose(Guilds.Kind.Pact, address(diplomacy), bond, other, 10, minimum);
    }

    function _assertUnconsumed(uint256 a, uint256 b, uint256 gA, uint256 gB) internal view {
        assertFalse(guilds.getProposal(a).executed);
        assertFalse(guilds.getProposal(b).executed);
        assertEq(guilds.treasuryOf(gA), 1000e18);
        assertEq(guilds.treasuryOf(gB), 1000e18);
        assertEq(token.balanceOf(address(diplomacy)), 0);
        assertEq(diplomacy.pactCount(), 0);
    }
}
