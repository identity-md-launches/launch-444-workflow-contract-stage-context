// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";

contract RealmTest is PactsBase {
    uint256 internal gA;
    uint256 internal gB;
    uint256 internal gC;

    function setUp() public override {
        super.setUp();
        gA = found(alice, "Alpha");
        gB = found(bob, "Beta");
        gC = found(carol, "Gamma");
    }

    // ------------------------------------------------------------- troops

    function test_buyTroopsSplitsFeeAndIncome() public {
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        uint256 cost = realm.buyTroops(100);
        assertEq(cost, 100e18);
        assertEq(token.balanceOf(alice), before - cost);
        assertEq(realm.reserveOf(gA), 100);
        assertEq(token.balanceOf(address(season)), 5e18);
        assertEq(season.prizePool(0), 5e18);
        assertEq(realm.incomePool(0), 95e18);
        assertEq(token.balanceOf(address(realm)), 95e18);
    }

    function test_buyTroopsRequiresGuildAndAmount() public {
        vm.prank(outsider);
        vm.expectRevert(Realm.NotInGuild.selector);
        realm.buyTroops(1);
        vm.prank(alice);
        vm.expectRevert(Realm.ZeroTroops.selector);
        realm.buyTroops(0);
    }

    function test_buyTroopsFromTreasury() public {
        vm.prank(dave);
        guilds.deposit(gA, 50e18);
        join(dave, gA);
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.TreasuryTroops, address(realm), 20e18, 0, 0, 0);
        vm.expectRevert(Guilds.ProposalNotApproved.selector);
        realm.buyTroopsFromTreasury(pid);
        voteYes(dave, pid);
        uint256 troops = realm.buyTroopsFromTreasury(pid);
        assertEq(troops, 20);
        assertEq(realm.reserveOf(gA), 20);
        assertEq(guilds.treasuryOf(gA), 30e18);
        assertEq(season.prizePool(0), 1e18);
        assertEq(realm.incomePool(0), 19e18);
        vm.expectRevert(Guilds.ProposalAlreadyExecuted.selector);
        realm.buyTroopsFromTreasury(pid);
    }

    function test_buyTroopsFromTreasuryRejectsFractionsAndWrongKind() public {
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.TreasuryTroops, address(realm), 1.5e18, 0, 0, 0);
        vm.expectRevert(Realm.NotWholeTroops.selector);
        realm.buyTroopsFromTreasury(pid);
        uint256 attack = proposeAttack(alice, 1, 0, 1);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.buyTroopsFromTreasury(attack);
    }

    // ------------------------------------------------------------- attacks

    function test_declareAttackValidation() public {
        buy(alice, 10);
        // wrong kind
        vm.prank(alice);
        uint256 payout = guilds.propose(Guilds.Kind.Payout, alice, 1, 0, 0, 0);
        vm.expectRevert(Realm.WrongKind.selector);
        realm.declareAttack(payout);
        // bad tile
        uint256 bad = proposeAttack(alice, 144, 0, 1);
        vm.expectRevert(Realm.InvalidTile.selector);
        realm.declareAttack(bad);
        // holder changed (tile is empty, proposal named Beta)
        uint256 stale = proposeAttack(alice, 3, gB, 1);
        vm.expectRevert(abi.encodeWithSelector(Realm.HolderChanged.selector, gB, 0));
        realm.declareAttack(stale);
        // not enough troops
        uint256 big = proposeAttack(alice, 3, 0, 11);
        vm.expectRevert(abi.encodeWithSelector(Realm.InsufficientTroops.selector, 10, 11));
        realm.declareAttack(big);
        // proposal not approved (two members, one vote)
        join(dave, gA);
        uint256 unapproved = proposeAttack(alice, 3, 0, 1);
        vm.expectRevert(Guilds.ProposalNotApproved.selector);
        realm.declareAttack(unapproved);
        // proposal whose target is not Realm cannot be consumed by Realm
        vm.prank(alice);
        uint256 wrongTarget = guilds.propose(Guilds.Kind.Attack, address(diplomacy), 0, 3, 0, 1);
        voteYes(dave, wrongTarget);
        vm.expectRevert(Guilds.NotTarget.selector);
        realm.declareAttack(wrongTarget);
    }

    function test_attackConsumesProposalAndCommitsTroops() public {
        buy(alice, 10);
        uint256 pid = attackNow(alice, 7, 0, 6);
        assertEq(realm.reserveOf(gA), 4);
        Realm.Attack[] memory list = realm.attacksOn(0, 7);
        assertEq(list.length, 1);
        assertEq(list[0].attacker, gA);
        assertEq(list[0].troops, 6);
        assertEq(list[0].proposalId, pid);
        assertEq(list[0].expectedHolder, 0);
        assertEq(realm.attackedTilesIn(0).length, 1);
        assertTrue(guilds.getProposal(pid).executed);
        // The consumed proposal cannot be replayed, and a second attack on the same tile in the same
        // epoch is rejected before Guilds is even consulted.
        vm.expectRevert(Realm.AlreadyAttacking.selector);
        realm.declareAttack(pid);
        uint256 again = proposeAttack(alice, 7, 0, 1);
        vm.expectRevert(Realm.AlreadyAttacking.selector);
        realm.declareAttack(again);
        // But a different tile is fine.
        attackNow(alice, 8, 0, 1);
        assertEq(realm.reserveOf(gA), 3);
    }

    function test_cannotAttackOwnTile() public {
        capture(alice, 7, 10);
        uint256 pid = proposeAttack(alice, 7, gA, 1);
        vm.expectRevert(Realm.CannotAttackOwnTile.selector);
        realm.declareAttack(pid);
    }

    function test_attackFailsWhenHolderChangedBetweenProposalAndDeclaration() public {
        capture(alice, 7, 10); // Alpha holds tile 7 with 10
        buy(bob, 30);
        buy(carol, 5);
        // Gamma proposes an attack naming Alpha, but Beta captures the tile first.
        uint256 gammaPid = proposeAttack(carol, 7, gA, 5);
        attackNow(bob, 7, gA, 30);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(7), gB);
        vm.expectRevert(abi.encodeWithSelector(Realm.HolderChanged.selector, gA, gB));
        realm.declareAttack(gammaPid);
    }

    // ---------------------------------------------------------- settlement

    function test_settleRequiresEndedEpoch() public {
        vm.expectRevert(Realm.EpochNotEnded.selector);
        realm.settle();
        vm.warp(START + EPOCH - 1);
        vm.expectRevert(Realm.EpochNotEnded.selector);
        realm.settle();
        vm.warp(START + EPOCH);
        assertEq(realm.settle(), 0);
        assertEq(realm.settledEpochs(), 1);
        assertTrue(realm.isEpochSettled(0));
        assertFalse(realm.isEpochSettled(1));
    }

    function test_settlePendingCatchesUpInOrder() public {
        warpToEpoch(5);
        assertEq(realm.settlePending(3), 3);
        assertEq(realm.settledEpochs(), 3);
        assertEq(realm.settlePending(10), 2);
        assertEq(realm.settledEpochs(), 5);
    }

    function test_singleAttackerTakesEmptyTileWithFullForce() public {
        buy(alice, 10);
        attackNow(alice, 0, 0, 10);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(0), gA);
        assertEq(tileGarrison(0), 10);
        assertEq(realm.tilesHeldBy(gA), 1);
        assertEq(realm.heldTiles(), 1);
        assertEq(realm.reserveOf(gA), 0);
    }

    function test_severalAttackersOnOneTileLargestWins() public {
        capture(alice, 7, 10); // holder Alpha, garrison 10
        buy(bob, 20);
        buy(carol, 5);
        attackNow(bob, 7, gA, 20);
        attackNow(carol, 7, gA, 5);
        nextEpoch();
        realm.settle();
        // total 35: Beta loses 20*15/35 = 8, Alpha loses 10*25/35 = 7, Gamma loses 5*30/35 = 4.
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 12);
        assertEq(realm.reserveOf(gA), 3);
        assertEq(realm.reserveOf(gB), 0);
        assertEq(realm.reserveOf(gC), 1);
        assertEq(realm.tilesHeldBy(gA), 0);
        assertEq(realm.tilesHeldBy(gB), 1);
        assertEq(realm.heldTiles(), 1);
        assertFalse(realm.hasPendingAttack(gB, gA));
        assertTroopsConserved(10 + 20 + 5, 8 + 7 + 4);
    }

    function test_tiedAttackersKeepTheHolder() public {
        capture(alice, 7, 10);
        buy(bob, 8);
        buy(carol, 8);
        attackNow(bob, 7, gA, 8);
        attackNow(carol, 7, gA, 8);
        nextEpoch();
        realm.settle();
        // total 26: Alpha loses 10*16/26 = 6, each attacker loses 8*18/26 = 5.
        assertEq(tileHolder(7), gA);
        assertEq(tileGarrison(7), 4);
        assertEq(realm.reserveOf(gB), 3);
        assertEq(realm.reserveOf(gC), 3);
        assertTroopsConserved(26, 16);
    }

    function test_tieWithHolderKeepsTheHolder() public {
        capture(alice, 7, 10);
        buy(bob, 10);
        attackNow(bob, 7, gA, 10);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(7), gA);
        assertEq(tileGarrison(7), 5);
        assertEq(realm.reserveOf(gB), 5);
    }

    function test_tiedAttackersOnEmptyTileLeaveItEmpty() public {
        buy(alice, 5);
        buy(bob, 5);
        attackNow(alice, 9, 0, 5);
        attackNow(bob, 9, 0, 5);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(9), 0);
        assertEq(realm.heldTiles(), 0);
        // each loses 5*5/10 = 2
        assertEq(realm.reserveOf(gA), 3);
        assertEq(realm.reserveOf(gB), 3);
    }

    function test_holderLosesTileToOverwhelmingForceAndSurvivorsRetreat() public {
        capture(alice, 7, 4);
        buy(bob, 100);
        attackNow(bob, 7, gA, 100);
        nextEpoch();
        realm.settle();
        // total 104: Beta loses 100*4/104 = 3, Alpha loses 4*100/104 = 3 -> 1 retreats.
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 97);
        assertEq(realm.reserveOf(gA), 1);
        assertEq(realm.tilesHeldBy(gA), 0);
    }

    function test_attacksOnSeveralTilesResolveInOneSettlement() public {
        buy(alice, 10);
        buy(bob, 10);
        attackNow(alice, 1, 0, 4);
        attackNow(alice, 2, 0, 6);
        attackNow(bob, 2, 0, 3);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(1), gA);
        assertEq(tileGarrison(1), 4);
        assertEq(tileHolder(2), gA);
        // total 9: Alpha loses 6*3/9 = 2, Beta loses 3*6/9 = 2.
        assertEq(tileGarrison(2), 4);
        assertEq(realm.reserveOf(gB), 8);
        assertEq(realm.tilesHeldBy(gA), 2);
        assertEq(realm.heldTiles(), 2);
    }

    /// @dev Settlement lags: an attack declared against the storage holder X in epoch 2 must not fight
    ///      whoever took the tile when epoch 1 settles. It is void and its troops come back.
    function test_attackIsVoidWhenAnEarlierEpochChangesTheHolderFirst() public {
        capture(alice, 7, 10); // epoch 0: Alpha takes tile 7; settled at epoch 1
        buy(bob, 100);
        attackNow(bob, 7, gA, 100); // epoch 1: Beta attacks Alpha, nobody settles
        nextEpoch(); // epoch 2: storage still says Alpha holds tile 7
        buy(carol, 200);
        uint256 pid = attackNow(carol, 7, gA, 200);
        assertEq(realm.reserveOf(gC), 0);
        nextEpoch();
        vm.expectEmit(true, true, true, true);
        emit Realm.AttackVoided(2, 7, gC, 200, gA, gB);
        realm.settlePending(2);
        // Epoch 1: Beta takes the tile (loses 100*10/110 = 9). Epoch 2: Gamma's attack is void.
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 91);
        assertEq(realm.reserveOf(gC), 200);
        assertEq(realm.tilesHeldBy(gC), 0);
        assertTrue(guilds.getProposal(pid).executed); // the proposal was spent all the same
        assertFalse(realm.hasPendingAttack(gC, gA));
        assertTroopsConserved(10 + 100 + 200, 9 + 9);
    }

    function test_voidAttacksDoNotChangeTheOutcomeForTheOthers() public {
        capture(alice, 7, 10); // settled at epoch 1
        uint256 gD = found(dave, "Delta");
        buy(bob, 100);
        buy(carol, 100);
        buy(dave, 30);
        attackNow(bob, 7, gA, 100); // epoch 1, unsettled
        nextEpoch(); // epoch 2
        attackNow(carol, 7, gA, 100); // names Alpha: void once Beta holds the tile
        realm.settle(); // epoch 1 settles: Beta holds tile 7 with 91
        attackNow(dave, 7, gB, 30); // names Beta: fights alone against the garrison of 91
        nextEpoch();
        realm.settle();
        // total 121: Delta loses 30*91/121 = 22, Beta loses 91*30/121 = 22.
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 69);
        assertEq(realm.reserveOf(gD), 8);
        assertEq(realm.reserveOf(gC), 100);
    }

    function test_attackOnAnEmptyTileIsVoidOnceItIsHeld() public {
        buy(alice, 10);
        buy(bob, 10);
        attackNow(alice, 5, 0, 10); // epoch 0
        nextEpoch();
        attackNow(bob, 5, 0, 10); // epoch 1, tile still empty in storage
        nextEpoch();
        realm.settlePending(2);
        assertEq(tileHolder(5), gA);
        assertEq(tileGarrison(5), 10);
        assertEq(realm.reserveOf(gB), 10);
    }

    // ------------------------------------------------- stepwise settlement

    function test_settleStepResolvesInBoundedStepsWithTheSameResult() public {
        capture(alice, 7, 10); // holder Alpha, garrison 10
        buy(bob, 21);
        buy(carol, 5);
        attackNow(bob, 7, gA, 20);
        attackNow(carol, 7, gA, 5);
        attackNow(bob, 8, 0, 1);
        buy(carol, 30); // income of epoch 1 goes to Alpha's one tile
        nextEpoch();
        assertFalse(realm.settleStep(1)); // income + compares Beta's force
        (bool started, uint256 done, uint256 total) = realm.settlementProgress();
        assertTrue(started);
        assertEq(done, 0);
        assertEq(total, 2);
        assertEq(realm.settledEpochs(), 1);
        // Epoch 0 carry 9.5e18 plus epoch 1 purchases (21 + 5 + 30 troops, 95% income) = 62.7e18.
        assertEq(realm.pendingIncome(gA), 62.7e18);
        assertEq(tileHolder(7), gA); // nothing resolved yet
        assertFalse(realm.settleStep(1)); // compares Gamma's force
        assertFalse(realm.settleStep(1)); // applies Beta's losses
        assertEq(tileHolder(7), gA);
        assertFalse(realm.settleStep(1)); // applies Gamma's losses and finishes tile 7
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 12);
        (, done,) = realm.settlementProgress();
        assertEq(done, 1);
        assertEq(realm.settledEpochs(), 1);
        assertTrue(realm.settleStep(5)); // tile 8 and completion
        assertEq(realm.settledEpochs(), 2);
        (started, done, total) = realm.settlementProgress();
        assertFalse(started);
        assertEq(done, 0);
        assertEq(total, 0);
        assertEq(tileHolder(8), gB);
        assertEq(realm.reserveOf(gA), 3);
        assertEq(realm.reserveOf(gC), 31);
        assertTroopsConserved(10 + 21 + 5 + 30, 8 + 7 + 4);
        vm.expectRevert(Realm.EpochNotEnded.selector);
        realm.settleStep(1);
        vm.expectRevert(Realm.ZeroSteps.selector);
        realm.settleStep(0);
    }

    function test_settleFinishesWhatSettleStepStarted() public {
        capture(alice, 7, 10);
        buy(bob, 20);
        buy(carol, 5);
        attackNow(bob, 7, gA, 20);
        attackNow(carol, 7, gA, 5);
        nextEpoch();
        assertFalse(realm.settleStep(1));
        assertEq(realm.settle(), 1);
        assertEq(realm.settledEpochs(), 2);
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 12);
    }

    function test_standingsRecordedOnTheLastStepOfTheSeason() public {
        buy(alice, 10);
        buy(bob, 10);
        warpToEpoch(EPOCHS_PER_SEASON - 1);
        realm.settlePending(EPOCHS_PER_SEASON);
        attackNow(alice, 0, 0, 10);
        attackNow(bob, 1, 0, 10);
        warpToEpoch(EPOCHS_PER_SEASON);
        assertFalse(realm.settleStep(1));
        (,, bool recorded) = realm.standingsOf(0);
        assertFalse(recorded);
        assertTrue(realm.settleStep(3));
        (uint256[3] memory ids,, bool done) = realm.standingsOf(0);
        assertTrue(done);
        assertEq(ids[0], gA);
        assertEq(ids[1], gB);
    }

    /// @dev One address founds, arms, attacks and leaves in a loop; settlement still fits in steps.
    function test_manyAttacksOnOneTileSettleInBoundedSteps() public {
        capture(alice, 0, 50);
        uint256 spam = 300;
        vm.startPrank(outsider);
        for (uint256 i; i < spam; ++i) {
            guilds.found("g");
            realm.buyTroops(1);
            uint256 pid = guilds.propose(Guilds.Kind.Attack, address(realm), 0, 0, gA, 1);
            realm.declareAttack(pid);
            guilds.leave();
        }
        vm.stopPrank();
        nextEpoch();
        uint256 steps;
        bool completed;
        while (!completed) {
            uint256 before = gasleft();
            completed = realm.settleStep(50);
            assertLt(before - gasleft(), 3_000_000, "step exceeds its gas bound");
            steps += 1;
        }
        assertEq(steps, 12); // 300 compares + 300 applies, 50 per step
        assertEq(realm.settledEpochs(), 2);
        // 300 one-troop attacks against 50: the holder keeps the tile and loses 50*300/350 = 42.
        assertEq(tileHolder(0), gA);
        assertEq(tileGarrison(0), 8);
        // Each attacker loses 1*349/350 = 0 and gets its troop back.
        assertEq(realm.reserveOf(gC + 1), 1);
        assertEq(realm.reserveOf(gC + spam), 1);
    }

    function test_pendingAttackFlagClearsAtSettlement() public {
        capture(alice, 7, 10);
        buy(bob, 3);
        attackNow(bob, 7, gA, 3);
        assertTrue(realm.hasPendingAttack(gB, gA));
        assertFalse(realm.hasPendingAttack(gA, gB));
        nextEpoch();
        assertTrue(realm.hasPendingAttack(gB, gA));
        realm.settle();
        assertFalse(realm.hasPendingAttack(gB, gA));
    }

    // -------------------------------------------------------------- income

    function test_incomeGoesToHoldersPerTile() public {
        // Alpha takes two tiles, Beta one, during epoch 0.
        buy(alice, 20);
        buy(bob, 10);
        attackNow(alice, 1, 0, 10);
        attackNow(alice, 2, 0, 10);
        attackNow(bob, 3, 0, 10);
        nextEpoch();
        realm.settle(); // epoch 0: income 28.5e18 with no holders -> carried
        assertEq(realm.incomeCarry(), 28.5e18);
        assertEq(realm.pendingIncome(gA), 0);

        // Epoch 1: Gamma buys 30 troops -> 28.5e18 income, plus carry = 57e18 over 3 tiles = 19e18 each.
        buy(carol, 30);
        nextEpoch();
        realm.settle();
        assertEq(realm.incomeCarry(), 0);
        assertEq(realm.pendingIncome(gA), 38e18);
        assertEq(realm.pendingIncome(gB), 19e18);
        assertEq(realm.pendingIncome(gC), 0);

        uint256 collected = realm.collectIncome(gA);
        assertEq(collected, 38e18);
        assertEq(guilds.treasuryOf(gA), 38e18);
        assertEq(realm.pendingIncome(gA), 0);
        assertEq(realm.collectIncome(gA), 0);
        // Realm holds exactly what is still owed to Beta.
        assertEq(token.balanceOf(address(realm)), 19e18);
    }

    function test_incomeAccruesAcrossHolderChanges() public {
        capture(alice, 7, 10); // epoch 0 income (9.5e18) carried, Alpha holds from epoch 1
        buy(bob, 30); // epoch 1: 28.5e18 income + 9.5e18 carry -> 38e18 to Alpha's one tile
        attackNow(bob, 7, gA, 30); // Beta takes the tile at the end of epoch 1
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(7), gB);
        assertEq(realm.pendingIncome(gA), 38e18);
        assertEq(realm.pendingIncome(gB), 0);
        buy(carol, 10); // epoch 2: 9.5e18 income to Beta
        nextEpoch();
        realm.settle();
        assertEq(realm.pendingIncome(gA), 38e18);
        assertEq(realm.pendingIncome(gB), 9.5e18);
    }

    function test_roundingDustIsCarried() public {
        buy(alice, 1);
        buy(bob, 1);
        attackNow(alice, 1, 0, 1);
        attackNow(bob, 2, 0, 1);
        nextEpoch();
        realm.settle(); // carry 1.9e18, no holders yet
        buy(carol, 1); // 0.95e18 -> pool 2.85e18 over 2 tiles
        nextEpoch();
        realm.settle();
        assertEq(realm.incomeCarry(), 2.85e18 % 2);
        assertEq(realm.pendingIncome(gA) + realm.pendingIncome(gB) + realm.incomeCarry(), 2.85e18);
    }

    // ----------------------------------------------------------- standings

    function test_standingsRecordedAtSeasonEnd() public {
        buy(alice, 30);
        buy(bob, 20);
        buy(carol, 10);
        attackNow(alice, 0, 0, 10);
        attackNow(alice, 1, 0, 10);
        attackNow(alice, 2, 0, 10);
        attackNow(bob, 3, 0, 10);
        attackNow(bob, 4, 0, 10);
        attackNow(carol, 5, 0, 10);
        warpToEpoch(EPOCHS_PER_SEASON);
        (,, bool recorded) = realm.standingsOf(0);
        assertFalse(recorded);
        realm.settlePending(EPOCHS_PER_SEASON);
        (uint256[3] memory ids, uint256[3] memory tiles, bool done) = realm.standingsOf(0);
        assertTrue(done);
        assertEq(ids[0], gA);
        assertEq(ids[1], gB);
        assertEq(ids[2], gC);
        assertEq(tiles[0], 3);
        assertEq(tiles[1], 2);
        assertEq(tiles[2], 1);
    }

    function test_standingsTieBreakByOlderGuildAndEmptySlots() public {
        buy(bob, 10);
        buy(carol, 10);
        attackNow(carol, 10, 0, 10); // Gamma declared first, but Beta is the older guild
        attackNow(bob, 11, 0, 10);
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        (uint256[3] memory ids, uint256[3] memory tiles,) = realm.standingsOf(0);
        assertEq(ids[0], gB);
        assertEq(ids[1], gC);
        assertEq(ids[2], 0);
        assertEq(tiles[0], 1);
        assertEq(tiles[1], 1);
        assertEq(tiles[2], 0);
    }

    function test_standingsSnapshotNotChangedByNextSeason() public {
        capture(alice, 0, 10);
        warpToEpoch(EPOCHS_PER_SEASON + 1);
        realm.settlePending(EPOCHS_PER_SEASON + 1);
        (uint256[3] memory ids,,) = realm.standingsOf(0);
        assertEq(ids[0], gA);
        // Beta takes the tile in season 1; season 0 standings stay put.
        buy(bob, 100);
        attackNow(bob, 0, gA, 100);
        nextEpoch();
        realm.settle();
        (ids,,) = realm.standingsOf(0);
        assertEq(ids[0], gA);
        (,, bool s1) = realm.standingsOf(1);
        assertFalse(s1);
    }

    // ----------------------------------------------------------------- misc

    function test_clockViews() public view {
        assertEq(realm.genesis(), START);
        assertEq(realm.epochsPerSeason(), 168);
        assertEq(realm.epochEnd(0), START + EPOCH);
        assertEq(realm.seasonEnd(0), START + SEASON);
        assertEq(realm.seasonOfEpoch(167), 0);
        assertEq(realm.seasonOfEpoch(168), 1);
        assertEq(realm.currentSeason(), 0);
    }

    function test_mapView() public {
        capture(alice, 143, 3);
        (uint256[144] memory holders, uint256[144] memory garrisons) = realm.map();
        assertEq(holders[143], gA);
        assertEq(garrisons[143], 3);
        assertEq(holders[0], 0);
        vm.expectRevert(Realm.InvalidTile.selector);
        realm.tile(144);
    }

    function test_constructorRejectsBadArguments() public {
        IERC20 t = IERC20(address(token));
        vm.expectRevert(Realm.InvalidParameters.selector);
        new Realm(t, guilds, EPOCH, SEASON + 1, PRICE, FEE_BPS); // season not a multiple of epoch
        vm.expectRevert(Realm.InvalidParameters.selector);
        new Realm(t, guilds, EPOCH, SEASON, 0, FEE_BPS); // zero price
        vm.expectRevert(Realm.InvalidParameters.selector);
        new Realm(t, guilds, EPOCH, SEASON, PRICE, 10_001); // fee over 100%
        vm.expectRevert(Realm.InvalidParameters.selector);
        new Realm(t, guilds, 2 * EPOCH, SEASON, PRICE, FEE_BPS); // clock differs from Guilds
        vm.expectRevert(Realm.ZeroAddress.selector);
        new Realm(t, Guilds(address(0)), EPOCH, SEASON, PRICE, FEE_BPS);
    }

    function test_zeroFeeSendsNothingToSeason() public {
        Realm r = new Realm(IERC20(address(token)), guilds, EPOCH, SEASON, PRICE, 0);
        vm.prank(alice);
        token.approve(address(r), type(uint256).max);
        vm.prank(alice);
        r.buyTroops(3);
        assertEq(token.balanceOf(address(r.season())), 0);
        assertEq(r.incomePool(0), 3e18);
    }

    // ------------------------------------------------------------- helpers

    function assertTroopsConserved(uint256 bought, uint256 lost) internal view {
        uint256 alive = realm.reserveOf(gA) + realm.reserveOf(gB) + realm.reserveOf(gC);
        (, uint256[144] memory garrisons) = realm.map();
        for (uint256 i; i < 144; ++i) {
            alive += garrisons[i];
        }
        assertEq(alive + lost, bought, "troops not conserved");
    }
}
