// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";

/// @dev Adversarial coverage of what the second round added: void attacks, stepwise settlement, the
///      member-only gate on betrayals and in-order season closing. Inputs the revision did not
///      obviously consider: a budget of one, a budget larger than the work, an epoch with nothing to
///      do, actions interleaved between settlement steps, and every attack on a tile being void.
/// forge-config: default.fuzz.runs = 256
contract RevisionEdgeCasesTest is PactsBase {
    uint256 internal gA;
    uint256 internal gB;
    uint256 internal gC;
    uint256 internal gD;

    address[4] internal players;
    uint256[4] internal guildIds;

    function setUp() public override {
        super.setUp();
        gA = found(alice, "Alpha");
        gB = found(bob, "Beta");
        gC = found(carol, "Gamma");
        gD = found(dave, "Delta");
        players = [alice, bob, carol, dave];
        guildIds = [gA, gB, gC, gD];
    }

    // ------------------------------------------------ helpers for a twin realm

    /// @dev A second Realm on the same Guilds and token, so the same script can be settled two ways.
    function _twin() internal returns (Realm other) {
        other = new Realm(IERC20(address(token)), guilds, EPOCH, SEASON, PRICE, FEE_BPS);
        for (uint256 i; i < 4; ++i) {
            vm.prank(players[i]);
            token.approve(address(other), type(uint256).max);
        }
    }

    function _buyOn(Realm r, address who, uint256 troops) internal {
        vm.prank(who);
        r.buyTroops(troops);
    }

    function _attackOn(Realm r, address who, uint256 tile, uint256 holder, uint256 troops) internal {
        vm.prank(who);
        uint256 pid = guilds.propose(Guilds.Kind.Attack, address(r), 0, tile, holder, troops);
        vm.prank(who);
        r.declareAttack(pid);
    }

    function _stepUntilDone(Realm r, uint256 budget) internal returns (uint256 steps) {
        bool done;
        while (!done) {
            uint256 settledBefore = r.settledEpochs();
            (, uint256 tilesDoneBefore,) = r.settlementProgress();
            done = r.settleStep(budget);
            steps += 1;
            (bool started, uint256 tilesDone,) = r.settlementProgress();
            if (done) {
                assertEq(r.settledEpochs(), settledBefore + 1, "completion advances settledEpochs by one");
                assertFalse(started, "progress cleared on completion");
                assertEq(tilesDone, 0);
            } else {
                assertEq(r.settledEpochs(), settledBefore, "a partial step must not advance settledEpochs");
                assertTrue(started, "a partial step leaves the settlement started");
                assertGe(tilesDone, tilesDoneBefore, "tile progress never goes backwards");
            }
        }
    }

    function _assertSameState(Realm a, Realm b) internal view {
        (uint256[144] memory ha, uint256[144] memory ga) = a.map();
        (uint256[144] memory hb, uint256[144] memory gb) = b.map();
        for (uint256 i; i < 144; ++i) {
            assertEq(ha[i], hb[i], "holder differs");
            assertEq(ga[i], gb[i], "garrison differs");
        }
        for (uint256 i; i < 4; ++i) {
            assertEq(a.reserveOf(guildIds[i]), b.reserveOf(guildIds[i]), "reserve differs");
            assertEq(a.pendingIncome(guildIds[i]), b.pendingIncome(guildIds[i]), "income differs");
            assertEq(a.tilesHeldBy(guildIds[i]), b.tilesHeldBy(guildIds[i]), "tile count differs");
        }
        assertEq(a.heldTiles(), b.heldTiles());
        assertEq(a.incomeCarry(), b.incomeCarry());
        assertEq(a.accIncomePerTile(), b.accIncomePerTile());
        assertEq(a.settledEpochs(), b.settledEpochs());
        assertEq(token.balanceOf(address(a)), token.balanceOf(address(b)));
    }

    // ---------------------------------------------------- stepwise settlement

    /// @dev The same random script settled in one shot and in steps of `budget` attack visits ends in
    ///      the same state, and the number of steps is exactly what the documented budget implies.
    function testFuzz_stepwiseSettlementMatchesOneShot(uint256 seed, uint8 budgetSeed) public {
        Realm other = _twin();
        uint256 budget = bound(budgetSeed, 1, 9);

        // Epoch 0: Alpha and Beta take tiles 0 and 1 in both realms.
        _buyOn(realm, alice, 10);
        _buyOn(other, alice, 10);
        _buyOn(realm, bob, 6);
        _buyOn(other, bob, 6);
        _attackOn(realm, alice, 0, 0, 10);
        _attackOn(other, alice, 0, 0, 10);
        _attackOn(realm, bob, 1, 0, 6);
        _attackOn(other, bob, 1, 0, 6);
        nextEpoch();
        realm.settle();
        _stepUntilDone(other, budget);
        _assertSameState(realm, other);

        // Epoch 1: up to eight random attacks over tiles 0..2 by the four guilds.
        bool[3][4] memory used;
        uint256 entries;
        for (uint256 k; k < 8; ++k) {
            seed = uint256(keccak256(abi.encode(seed, k)));
            uint256 who = seed % 4;
            uint256 tile = (seed >> 8) % 3;
            uint256 troops = 1 + (seed >> 16) % 15;
            uint256 holder = tileHolder(tile);
            if (holder == guildIds[who] || used[who][tile]) continue;
            used[who][tile] = true;
            entries += 1;
            _buyOn(realm, players[who], troops);
            _buyOn(other, players[who], troops);
            _attackOn(realm, players[who], tile, holder, troops);
            _attackOn(other, players[who], tile, holder, troops);
        }
        _buyOn(realm, carol, 1 + seed % 40); // some income for the epoch
        _buyOn(other, carol, 1 + seed % 40);
        nextEpoch();
        realm.settle();
        uint256 steps = _stepUntilDone(other, budget);
        uint256 visits = 2 * entries; // every attack is compared once and applied once
        assertEq(steps, visits == 0 ? 1 : (visits + budget - 1) / budget, "steps exceed the budget");
        _assertSameState(realm, other);
    }

    function test_settleStepOnAQuietEpochCompletesInOneStepAndDistributesIncomeOnce() public {
        capture(alice, 7, 3); // now in epoch 1
        buy(bob, 20); // 19e18 income for Alpha's one tile
        nextEpoch();
        uint256 carryBefore = realm.incomeCarry();
        assertTrue(realm.settleStep(1));
        assertEq(realm.settledEpochs(), 2);
        assertEq(realm.pendingIncome(gA), carryBefore + 19e18);
        (bool started, uint256 done, uint256 total) = realm.settlementProgress();
        assertFalse(started);
        assertEq(done, 0);
        assertEq(total, 0);
        // Nothing left to settle: neither entry point may run the distribution again.
        vm.expectRevert(Realm.EpochNotEnded.selector);
        realm.settleStep(type(uint256).max);
        vm.expectRevert(Realm.EpochNotEnded.selector);
        realm.settle();
        assertEq(realm.pendingIncome(gA), carryBefore + 19e18);
    }

    function test_settleStepWithAnUnboundedBudgetIsOneShot() public {
        capture(alice, 7, 10);
        buy(bob, 4);
        buy(carol, 4);
        attackNow(bob, 7, gA, 4);
        attackNow(carol, 8, 0, 4);
        nextEpoch();
        assertTrue(realm.settleStep(type(uint256).max));
        assertEq(realm.settledEpochs(), 2);
        assertEq(tileHolder(7), gA);
        assertEq(tileHolder(8), gC);
    }

    function test_incomeIsDistributedOnTheFirstStepOnlyAndLaterPurchasesWait() public {
        capture(alice, 7, 10); // epoch 1
        buy(bob, 5);
        buy(carol, 5);
        attackNow(bob, 7, gA, 5);
        attackNow(carol, 7, gA, 5);
        nextEpoch(); // epoch 2
        assertFalse(realm.settleStep(1));
        uint256 pending = realm.pendingIncome(gA);
        // Epoch 0 carry 9.5e18 (no holders yet) plus epoch 1 income 9.5e18, one tile held.
        assertEq(pending, 19e18, "first step pays income");
        assertEq(realm.incomeCarry(), 0);
        // A purchase between steps books to the current epoch and changes nothing already paid.
        buy(dave, 8);
        assertEq(realm.incomePool(2), 7.6e18);
        assertFalse(realm.settleStep(1));
        assertEq(realm.pendingIncome(gA), pending, "second step must not pay income again");
        // Collecting between steps moves exactly the distributed amount and nothing more.
        assertEq(realm.collectIncome(gA), pending);
        assertEq(realm.pendingIncome(gA), 0);
        assertFalse(realm.settleStep(1));
        assertTrue(realm.settleStep(1));
        assertEq(realm.pendingIncome(gA), 0, "completion pays nothing extra");
        assertEq(realm.settledEpochs(), 2);
        // Tie 5 vs 5 on top of a garrison of 10: holder keeps it; total 20: Alpha loses 10*10/20 = 5.
        assertEq(tileHolder(7), gA);
        assertEq(tileGarrison(7), 5);
        // The mid-settlement purchase is distributed when its own epoch settles.
        nextEpoch();
        realm.settle();
        assertEq(realm.pendingIncome(gA), 7.6e18);
    }

    /// @dev An attack declared while a settlement is half done names the holder storage shows at that
    ///      moment. When the settlement completes and the tile changes hands, that attack is void.
    function test_attackDeclaredBetweenStepsIsVoidOnceTheTileFlips() public {
        capture(alice, 7, 10); // epoch 1
        buy(bob, 100);
        attackNow(bob, 7, gA, 100);
        nextEpoch(); // epoch 2
        assertFalse(realm.settleStep(1)); // income paid, Beta compared, tile 7 still Alpha's in storage
        assertEq(tileHolder(7), gA);
        buy(carol, 50);
        uint256 pid = attackNow(carol, 7, gA, 50); // epoch 2, names Alpha
        assertTrue(realm.hasPendingAttack(gC, gA));
        assertTrue(realm.settleStep(10));
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 91);
        nextEpoch();
        vm.expectEmit(true, true, true, true);
        emit Realm.AttackVoided(2, 7, gC, 50, gA, gB);
        realm.settle();
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 91, "a void attack must not touch the garrison");
        assertEq(realm.reserveOf(gC), 50, "void attack refunded in full");
        assertFalse(realm.hasPendingAttack(gC, gA));
        assertTrue(guilds.getProposal(pid).executed);
    }

    function test_everyAttackOnATileVoidLeavesItExactlyAsItWas() public {
        capture(alice, 7, 10); // epoch 1
        buy(bob, 100);
        attackNow(bob, 7, gA, 100); // epoch 1, unsettled
        nextEpoch(); // epoch 2: storage still shows Alpha
        buy(carol, 30);
        buy(dave, 30);
        attackNow(carol, 7, gA, 30);
        attackNow(dave, 7, gA, 30);
        nextEpoch();
        realm.settle(); // epoch 1: Beta takes tile 7 with 91
        assertEq(tileHolder(7), gB);
        vm.expectEmit(true, true, true, true);
        emit Realm.TileResolved(2, 7, gB, gB, 91);
        realm.settle(); // epoch 2: both attacks void
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 91);
        assertEq(realm.reserveOf(gC), 30);
        assertEq(realm.reserveOf(gD), 30);
        assertEq(realm.reserveOf(gB), 0);
        assertEq(realm.tilesHeldBy(gB), 1);
        assertEq(realm.heldTiles(), 1);
    }

    function test_settlePendingCountsAHalfDoneEpochOnce() public {
        capture(alice, 7, 10); // epoch 1
        buy(bob, 3);
        attackNow(bob, 7, gA, 3);
        warpToEpoch(4); // epochs 1, 2 and 3 have ended
        assertFalse(realm.settleStep(1));
        assertEq(realm.settledEpochs(), 1);
        assertEq(realm.settlePending(10), 3);
        assertEq(realm.settledEpochs(), 4);
        assertEq(tileHolder(7), gA);
        assertEq(tileGarrison(7), 8); // total 13: Alpha loses 10*3/13 = 2
        assertEq(realm.reserveOf(gB), 1); // Beta loses 3*10/13 = 2
    }

    function test_stepBudgetIsAttackVisitsNotTiles() public {
        // Three tiles with one attack each need six visits: settleStep(2) takes exactly three steps
        // and settleStep(6) exactly one.
        buy(alice, 3);
        attackNow(alice, 0, 0, 1);
        attackNow(alice, 1, 0, 1);
        attackNow(alice, 2, 0, 1);
        nextEpoch();
        assertFalse(realm.settleStep(2));
        (, uint256 done,) = realm.settlementProgress();
        assertEq(done, 1);
        assertFalse(realm.settleStep(2));
        (, done,) = realm.settlementProgress();
        assertEq(done, 2);
        assertTrue(realm.settleStep(2));
        assertEq(realm.tilesHeldBy(gA), 3);
    }

    /// @dev The stepwise path handles the season boundary: standings are recorded only when the last
    ///      step completes, and a season cannot close on a half-settled last epoch.
    function test_seasonCannotCloseOnAHalfSettledLastEpoch() public {
        buy(alice, 10);
        buy(bob, 5);
        warpToEpoch(EPOCHS_PER_SEASON - 1);
        realm.settlePending(EPOCHS_PER_SEASON);
        attackNow(alice, 0, 0, 10);
        attackNow(bob, 1, 0, 5);
        warpToEpoch(EPOCHS_PER_SEASON);
        assertFalse(realm.settleStep(1));
        vm.expectRevert(Season.SeasonNotRecorded.selector);
        season.close(0);
        assertTrue(realm.settleStep(100));
        season.close(0);
        Season.Result memory r = season.getResult(0);
        assertEq(r.guildIds[0], gA);
        assertEq(r.guildIds[1], gB);
        assertEq(r.tiles[0], 1);
    }

    // -------------------------------------------------- betrayal declaration

    /// @dev `wouldBreakPact` agrees with what `onAttack` then does, for every duration and delay, and
    ///      the member gate applies exactly while it is true.
    function testFuzz_wouldBreakPactPredictsTheDeclarationOutcome(uint8 epochsSeed, uint8 delaySeed) public {
        uint256 epochs = bound(epochsSeed, 1, 12);
        uint256 delay = bound(delaySeed, 0, 15);
        capture(bob, 7, 10); // epoch 1
        vm.prank(erin);
        guilds.deposit(gA, 1e18);
        vm.prank(erin);
        guilds.deposit(gB, 1e18);
        uint256 pactId = diplomacy.sign(proposePact(alice, gB, 1e18, epochs), proposePact(bob, gA, 1e18, epochs));
        assertFalse(diplomacy.wouldBreakPact(gA, gA, 1));
        assertFalse(diplomacy.wouldBreakPact(0, gB, 1));
        assertFalse(diplomacy.wouldBreakPact(gA, 0, 1));
        assertFalse(diplomacy.wouldBreakPact(gA, gC, 1));
        warpToEpoch(1 + delay);
        bool predicted = diplomacy.wouldBreakPact(gA, gB, realm.currentEpoch());
        assertEq(predicted, delay < epochs);
        assertEq(diplomacy.wouldBreakPact(gB, gA, realm.currentEpoch()), predicted, "symmetric");
        buy(alice, 1);
        uint256 pid = proposeAttack(alice, 7, gB, 1);
        if (predicted) {
            vm.prank(bob);
            vm.expectRevert(Realm.BetrayalRequiresMember.selector);
            realm.declareAttack(pid);
            declareAs(alice, pid);
            assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Broken));
        } else {
            vm.prank(bob);
            realm.declareAttack(pid);
            assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Expired));
        }
        assertFalse(diplomacy.wouldBreakPact(gA, gB, realm.currentEpoch()), "a finished pact cannot be broken");
    }

    /// @dev Signing does not look at undeclared proposals, so an approved attack can outlive the
    ///      signature; afterwards only a member can declare it and doing so is a betrayal.
    function test_pactSignsOverAnUndeclaredApprovedAttackWhichOnlyMembersMayThenDeclare() public {
        capture(bob, 7, 10); // epoch 1
        buy(alice, 2);
        uint256 stale = proposeAttack(alice, 7, gB, 2);
        assertTrue(guilds.isApproved(stale));
        assertFalse(realm.hasPendingAttack(gA, gB), "an undeclared proposal is not a pending attack");
        vm.prank(erin);
        guilds.deposit(gA, 5e18);
        vm.prank(erin);
        guilds.deposit(gB, 5e18);
        uint256 pactId = diplomacy.sign(proposePact(alice, gB, 5e18, 3), proposePact(bob, gA, 5e18, 3));
        vm.prank(bob);
        vm.expectRevert(Realm.BetrayalRequiresMember.selector);
        realm.declareAttack(stale);
        vm.prank(outsider);
        vm.expectRevert(Realm.BetrayalRequiresMember.selector);
        realm.declareAttack(stale);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Active));
        assertEq(realm.reserveOf(gA), 2);
        // Letting it expire is the safe way out: after that nobody can declare it at all.
        warpToEpoch(3);
        vm.prank(alice);
        vm.expectRevert(Guilds.ProposalExpired.selector);
        realm.declareAttack(stale);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Active));
        assertEq(guilds.treasuryOf(gB), 0);
    }

    function test_memberGateDoesNotApplyToAttacksOnEmptyOrThirdPartyTiles() public {
        capture(carol, 8, 4); // epoch 1
        vm.prank(erin);
        guilds.deposit(gA, 1e18);
        vm.prank(erin);
        guilds.deposit(gB, 1e18);
        diplomacy.sign(proposePact(alice, gB, 1e18, 5), proposePact(bob, gA, 1e18, 5));
        buy(alice, 2);
        uint256 onEmpty = proposeAttack(alice, 9, 0, 1);
        uint256 onGamma = proposeAttack(alice, 8, gC, 1);
        vm.prank(bob); // the partner may declare attacks that do not concern the pact
        realm.declareAttack(onEmpty);
        vm.prank(outsider);
        realm.declareAttack(onGamma);
        assertEq(realm.reserveOf(gA), 0);
        assertEq(diplomacy.betrayals(gA, 0), 0);
    }

    /// @dev A betrayal is settled at declaration: even when the attack later turns out void because
    ///      the partner had already lost the tile in a lagging epoch, the bonds have moved.
    function test_betrayalOfAStaleHolderIsSlashedAtDeclarationAndTheAttackIsVoid() public {
        capture(bob, 7, 10); // epoch 1
        vm.prank(erin);
        guilds.deposit(gA, 2e18);
        vm.prank(erin);
        guilds.deposit(gB, 3e18);
        uint256 pactId = diplomacy.sign(proposePact(alice, gB, 2e18, 6), proposePact(bob, gA, 2e18, 6));
        buy(carol, 100);
        attackNow(carol, 7, gB, 100); // epoch 1, not settled
        nextEpoch(); // epoch 2: storage still says Beta holds tile 7
        buy(alice, 5);
        betrayNow(alice, 7, gB, 5);
        assertEq(uint256(diplomacy.getPact(pactId).status), uint256(Diplomacy.Status.Broken));
        assertEq(guilds.treasuryOf(gB), 1e18 + 4e18);
        assertEq(guilds.treasuryOf(gA), 0);
        nextEpoch();
        realm.settlePending(2);
        assertEq(tileHolder(7), gC);
        assertEq(realm.reserveOf(gA), 5, "the void attack is refunded");
        assertEq(diplomacy.betrayals(gA, 0), 1, "but the betrayal stands");
        assertEq(guilds.treasuryOf(gB), 5e18);
    }

    // ------------------------------------------------------- season ordering

    function test_seasonsCloseStrictlyInOrderAndClaimsWaitForTheClose() public {
        capture(alice, 0, 1);
        warpToEpoch(3 * EPOCHS_PER_SEASON);
        realm.settlePending(3 * EPOCHS_PER_SEASON);
        for (uint256 s; s < 3; ++s) {
            (,, bool recorded) = realm.standingsOf(s);
            assertTrue(recorded);
        }
        vm.expectRevert(Season.PreviousSeasonNotClosed.selector);
        season.close(2);
        vm.expectRevert(Season.PreviousSeasonNotClosed.selector);
        season.close(1);
        vm.prank(alice);
        vm.expectRevert(Season.SeasonNotClosed.selector);
        season.claim(1, gA);
        season.close(0);
        vm.expectRevert(Season.PreviousSeasonNotClosed.selector);
        season.close(2);
        season.close(1);
        season.close(2);
        vm.expectRevert(Season.SeasonAlreadyClosed.selector);
        season.close(1);
        vm.expectRevert(Season.SeasonNotEnded.selector);
        season.close(3);
        vm.prank(alice);
        (uint256 got,) = season.claim(2, gA);
        assertEq(got, season.getResult(2).perMember[0]);
        // The single 0.05e18 fee halves at every close: 50% is won, the rest rolls forward.
        assertEq(season.getResult(0).pool, 0.05e18);
        assertEq(season.getResult(1).pool, 0.025e18);
        assertEq(season.getResult(2).pool, 0.0125e18);
        assertEq(got, 0.00625e18);
    }

    function test_rolloverChainsThroughConsecutiveEmptySeasons() public {
        // Fees are paid in season 0 while nobody holds a tile; seasons 0 and 1 roll everything into
        // season 2, which Alpha wins alone.
        buy(alice, 100); // fee 5e18
        warpToEpoch(2 * EPOCHS_PER_SEASON);
        realm.settlePending(2 * EPOCHS_PER_SEASON);
        attackNow(alice, 0, 0, 1);
        warpToEpoch(3 * EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        assertEq(season.getResult(0).rollover, 5e18);
        season.close(1);
        assertEq(season.getResult(1).pool, 5e18);
        assertEq(season.getResult(1).rollover, 5e18);
        season.close(2);
        Season.Result memory r = season.getResult(2);
        assertEq(r.pool, 5e18);
        assertEq(r.guildPrize[0], 2.5e18);
        assertEq(r.rollover, 2.5e18);
        vm.prank(alice);
        (uint256 got,) = season.claim(2, gA);
        assertEq(got, 2.5e18);
        assertEq(token.balanceOf(address(season)), 2.5e18);
        assertEq(season.prizePool(3), 2.5e18);
    }
}
