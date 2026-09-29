// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";

contract DiplomacyTest is PactsBase {
    uint256 internal gA;
    uint256 internal gB;
    uint256 internal gC;

    function setUp() public override {
        super.setUp();
        gA = found(alice, "Alpha");
        gB = found(bob, "Beta");
        gC = found(carol, "Gamma");
        // Fund the treasuries that back the bonds.
        vm.prank(dave);
        guilds.deposit(gA, 100e18);
        vm.prank(dave);
        guilds.deposit(gB, 100e18);
        vm.prank(dave);
        guilds.deposit(gC, 100e18);
    }

    function signAB(uint256 bondA, uint256 bondB, uint256 epochs) internal returns (uint256 pactId) {
        uint256 pa = proposePact(alice, gB, bondA, epochs);
        uint256 pb = proposePact(bob, gA, bondB, epochs);
        pactId = diplomacy.sign(pa, pb);
    }

    // ------------------------------------------------------------- signing

    function test_signLocksBothBonds() public {
        uint256 pactId = signAB(10e18, 25e18, 3);
        assertEq(pactId, 1);
        Diplomacy.Pact memory p = diplomacy.getPact(1);
        assertEq(p.guildA, gA);
        assertEq(p.guildB, gB);
        assertEq(p.bondA, 10e18);
        assertEq(p.bondB, 25e18);
        assertEq(p.startEpoch, 0);
        assertEq(p.endEpoch, 2);
        assertEq(uint256(p.status), uint256(Diplomacy.Status.Active));
        assertEq(guilds.treasuryOf(gA), 90e18);
        assertEq(guilds.treasuryOf(gB), 75e18);
        assertEq(token.balanceOf(address(diplomacy)), 35e18);
        assertEq(diplomacy.activePactBetween(gA, gB), 1);
        assertEq(diplomacy.activePactBetween(gB, gA), 1);
    }

    function test_signNeedsMajorityOnBothSides() public {
        join(dave, gA);
        uint256 pa = proposePact(alice, gB, 10e18, 3);
        uint256 pb = proposePact(bob, gA, 10e18, 3);
        vm.expectRevert(Guilds.ProposalNotApproved.selector);
        diplomacy.sign(pa, pb);
        voteYes(dave, pa);
        diplomacy.sign(pa, pb);
    }

    function test_signRejectsMismatchedProposals() public {
        uint256 pa = proposePact(alice, gB, 10e18, 3);
        uint256 pc = proposePact(carol, gA, 10e18, 3); // Gamma names Alpha, but Alpha named Beta
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(pa, pc);

        uint256 pbWrongLength = proposePact(bob, gA, 10e18, 4);
        vm.expectRevert(Diplomacy.ProposalsDoNotMatch.selector);
        diplomacy.sign(pa, pbWrongLength);

        uint256 pa2 = proposePact(alice, gB, 5e18, 3);
        vm.expectRevert(Diplomacy.SameGuild.selector);
        diplomacy.sign(pa, pa2);

        uint256 attack = proposeAttack(alice, 1, 0, 1);
        vm.expectRevert(Diplomacy.WrongKind.selector);
        diplomacy.sign(attack, pa);
    }

    function test_signRejectsSecondActivePact() public {
        signAB(10e18, 10e18, 3);
        uint256 pa = proposePact(alice, gB, 1e18, 1);
        uint256 pb = proposePact(bob, gA, 1e18, 1);
        vm.expectRevert(Diplomacy.PactAlreadyActive.selector);
        diplomacy.sign(pa, pb);
    }

    function test_signFailsWhenTreasuryCannotCoverBond() public {
        uint256 pa = proposePact(alice, gB, 101e18, 3);
        uint256 pb = proposePact(bob, gA, 10e18, 3);
        vm.expectRevert(abi.encodeWithSelector(Guilds.InsufficientTreasury.selector, 100e18, 101e18));
        diplomacy.sign(pa, pb);
    }

    function test_signBlockedWhilePendingAttackBetweenTheTwo() public {
        capture(alice, 7, 10);
        buy(bob, 5);
        attackNow(bob, 7, gA, 5); // Beta attacks Alpha in the current epoch
        uint256 pa = proposePact(alice, gB, 10e18, 3);
        uint256 pb = proposePact(bob, gA, 10e18, 3);
        vm.expectRevert(Diplomacy.AttackPending.selector);
        diplomacy.sign(pa, pb);
        // Once the epoch is settled the pact can be signed.
        nextEpoch();
        realm.settle();
        diplomacy.sign(pa, pb);
        // An attack in the other direction blocks too.
        capture(bob, 8, 10);
        buy(carol, 5);
        attackNow(carol, 8, gB, 5);
        uint256 pb2 = proposePact(bob, gC, 1e18, 1);
        uint256 pc2 = proposePact(carol, gB, 1e18, 1);
        vm.expectRevert(Diplomacy.AttackPending.selector);
        diplomacy.sign(pb2, pc2);
    }

    function test_signFailsAfterProposalExpiry() public {
        uint256 pa = proposePact(alice, gB, 10e18, 3);
        uint256 pb = proposePact(bob, gA, 10e18, 3);
        warpToEpoch(2);
        vm.expectRevert(Guilds.ProposalExpired.selector);
        diplomacy.sign(pa, pb);
    }

    // -------------------------------------------------------------- expiry

    function test_expireReturnsBondsAfterLastEpoch() public {
        uint256 pactId = signAB(10e18, 25e18, 3); // epochs 0..2
        warpToEpoch(2);
        vm.expectRevert(Diplomacy.PactNotEnded.selector);
        diplomacy.expire(pactId);
        warpToEpoch(3);
        diplomacy.expire(pactId);
        assertEq(guilds.treasuryOf(gA), 100e18);
        assertEq(guilds.treasuryOf(gB), 100e18);
        assertEq(token.balanceOf(address(diplomacy)), 0);
        assertEq(diplomacy.activePactBetween(gA, gB), 0);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Expired));
        vm.expectRevert(Diplomacy.PactNotActive.selector);
        diplomacy.expire(pactId);
        vm.expectRevert(Diplomacy.NoSuchPact.selector);
        diplomacy.expire(2);
    }

    function test_newPactPossibleAfterExpiry() public {
        uint256 first = signAB(10e18, 10e18, 1);
        warpToEpoch(1);
        diplomacy.expire(first);
        assertEq(signAB(1e18, 1e18, 1), 2);
    }

    // ------------------------------------------------------------ betrayal

    function test_attackOnPartnerSlashesBondToVictim() public {
        capture(bob, 7, 10); // Beta holds tile 7 (settled in epoch 1)
        uint256 pactId = signAB(10e18, 25e18, 5); // epochs 1..5
        buy(alice, 3);
        uint256 treasuryB = guilds.treasuryOf(gB);
        betrayNow(alice, 7, gB, 3); // Alpha betrays Beta
        // Beta receives Alpha's 10e18 bond and its own 25e18 bond back.
        assertEq(guilds.treasuryOf(gB), treasuryB + 35e18);
        assertEq(guilds.treasuryOf(gA), 90e18);
        assertEq(token.balanceOf(address(diplomacy)), 0);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Broken));
        assertEq(diplomacy.activePactBetween(gA, gB), 0);
        assertEq(diplomacy.betrayals(gA, 0), 1);
        assertEq(diplomacy.betrayals(gB, 0), 0);
        // The attack itself still stands and resolves normally.
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(7), gB);
        vm.expectRevert(Diplomacy.PactNotActive.selector);
        diplomacy.expire(pactId);
    }

    function test_betrayalByTheOtherSideSlashesItsBond() public {
        capture(alice, 7, 10);
        signAB(10e18, 25e18, 5);
        buy(bob, 3);
        betrayNow(bob, 7, gA, 3);
        // Alpha gets Beta's 25e18 bond plus its own 10e18 back.
        assertEq(guilds.treasuryOf(gA), 100e18 + 25e18);
        assertEq(guilds.treasuryOf(gB), 75e18);
        assertEq(diplomacy.betrayals(gB, 0), 1);
    }

    function test_attackOnUnrelatedGuildDoesNotTouchThePact() public {
        capture(carol, 7, 10);
        uint256 pactId = signAB(10e18, 25e18, 5);
        buy(alice, 3);
        attackNow(alice, 7, gC, 3);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Active));
        assertEq(diplomacy.betrayals(gA, 0), 0);
        assertEq(token.balanceOf(address(diplomacy)), 35e18);
    }

    function test_attackOnEmptyTileIsNeverBetrayal() public {
        uint256 pactId = signAB(10e18, 25e18, 5);
        buy(alice, 3);
        attackNow(alice, 7, 0, 3);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Active));
    }

    function test_attackAfterPactRanOutExpiresItInsteadOfSlashing() public {
        capture(bob, 7, 10); // settled at epoch 1
        uint256 pactId = signAB(10e18, 25e18, 2); // epochs 1..2
        warpToEpoch(3);
        buy(alice, 3);
        attackNow(alice, 7, gB, 3);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Expired));
        assertEq(guilds.treasuryOf(gA), 100e18);
        assertEq(guilds.treasuryOf(gB), 100e18);
        assertEq(diplomacy.betrayals(gA, 0), 0);
    }

    function test_betrayalCountedInTheSeasonOfTheAttack() public {
        capture(bob, 7, 10);
        signAB(10e18, 25e18, 400); // spans into season 2
        warpToEpoch(EPOCHS_PER_SEASON + 3);
        realm.settlePending(EPOCHS_PER_SEASON + 3);
        buy(alice, 3);
        betrayNow(alice, 7, gB, 3);
        assertEq(diplomacy.betrayals(gA, 0), 0);
        assertEq(diplomacy.betrayals(gA, 1), 1);
    }

    function test_onlyAMemberOfTheAttackingGuildCanBreakAPact() public {
        capture(bob, 7, 10); // Beta holds tile 7
        uint256 pactId = signAB(10e18, 25e18, 5);
        buy(alice, 3);
        uint256 pid = proposeAttack(alice, 7, gB, 3);
        assertTrue(diplomacy.wouldBreakPact(gA, gB, realm.currentEpoch()));
        assertFalse(diplomacy.wouldBreakPact(gA, gC, realm.currentEpoch()));
        assertFalse(diplomacy.wouldBreakPact(gA, gB, 6)); // after the pact's last epoch
        uint256 treasuryA = guilds.treasuryOf(gA);
        uint256 treasuryB = guilds.treasuryOf(gB);
        // Neither the victim, an outsider nor the test contract can turn Alpha into a betrayer.
        vm.prank(bob);
        vm.expectRevert(Realm.BetrayalRequiresMember.selector);
        realm.declareAttack(pid);
        vm.prank(outsider);
        vm.expectRevert(Realm.BetrayalRequiresMember.selector);
        realm.declareAttack(pid);
        vm.expectRevert(Realm.BetrayalRequiresMember.selector);
        realm.declareAttack(pid);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Active));
        assertEq(guilds.treasuryOf(gA), treasuryA);
        assertEq(guilds.treasuryOf(gB), treasuryB);
        assertEq(realm.reserveOf(gA), 3);
        assertEq(diplomacy.betrayals(gA, 0), 0);
        // A member who joined after the proposal cannot vote on it, but is a member and may declare.
        join(erin, gA);
        declareAs(erin, pid);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Broken));
        assertEq(guilds.treasuryOf(gB), treasuryB + 35e18);
        assertEq(diplomacy.betrayals(gA, 0), 1);
    }

    function test_anyoneMayStillDeclareAnAttackThatBreaksNoPact() public {
        capture(bob, 7, 10);
        capture(carol, 8, 10);
        signAB(10e18, 25e18, 2); // epochs 2..3
        buy(alice, 6);
        // Not a partner: anyone declares.
        uint256 onGamma = proposeAttack(alice, 8, gC, 3);
        vm.prank(outsider);
        realm.declareAttack(onGamma);
        // Partner, but the pact has run out: anyone declares and the pact simply expires.
        warpToEpoch(4);
        uint256 onBeta = proposeAttack(alice, 7, gB, 3);
        vm.prank(outsider);
        realm.declareAttack(onBeta);
        assertEq(uint256(diplomacy.getPact(1).status), uint256(Diplomacy.Status.Expired));
        assertEq(diplomacy.betrayals(gA, 0), 0);
    }

    function test_onlyRealmMayReportAttacks() public {
        signAB(10e18, 25e18, 5);
        vm.prank(outsider);
        vm.expectRevert(Diplomacy.NotRealm.selector);
        diplomacy.onAttack(gA, gB, 0);
        vm.prank(alice);
        vm.expectRevert(Diplomacy.NotRealm.selector);
        diplomacy.onAttack(gA, gB, 0);
    }
}
