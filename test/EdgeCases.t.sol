// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";
import {Banners, IERC721Receiver} from "../src/Banners.sol";

contract GoodReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }
}

contract BadReceiver is IERC721Receiver {
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return 0xdeadbeef;
    }
}

/// @dev Inputs the implementation did not obviously consider: zero, one, the maximum, boundaries of
///      every time window, the same call twice, and callers who are not who the code assumed.
/// forge-config: default.fuzz.runs = 512
contract EdgeCasesTest is PactsBase {
    uint256 internal gA;
    uint256 internal gB;
    uint256 internal gC;
    uint256 internal gD;

    function setUp() public override {
        super.setUp();
        gA = found(alice, "Alpha");
        gB = found(bob, "Beta");
        gC = found(carol, "Gamma");
        gD = found(dave, "Delta");
    }

    // =========================================================== Guilds

    /// @dev A proposal is approved exactly when strictly more than half of the members present at
    ///      creation voted yes, whatever the member count.
    function testFuzz_majorityIsStrictForAnyGuildSize(uint8 membersSeed, uint8 yesSeed) public {
        address[7] memory pool = [alice, erin, frank, outsider, bob, carol, dave];
        uint256 members = bound(membersSeed, 1, 7);
        for (uint256 i = 1; i < members; ++i) {
            if (guilds.guildOf(pool[i]) != 0) {
                vm.prank(pool[i]);
                guilds.leave();
            }
            join(pool[i], gA);
        }
        vm.prank(erin);
        guilds.deposit(gA, 1e18);
        uint256 yes = bound(yesSeed, 1, members);
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, outsider, 1e18, 0, 0, 0);
        for (uint256 i = 1; i < members; ++i) {
            vm.prank(pool[i]);
            guilds.vote(pid, i < yes);
        }
        bool expected = yes * 2 > members;
        assertEq(guilds.isApproved(pid), expected);
        Guilds.Proposal memory p = guilds.getProposal(pid);
        assertEq(p.yesVotes, yes);
        assertEq(p.noVotes, members - yes);
        assertEq(p.eligibleVoters, members);
        if (expected) {
            guilds.execute(pid);
            assertEq(token.balanceOf(outsider), FUNDS + 1e18);
        } else {
            vm.expectRevert(Guilds.ProposalNotApproved.selector);
            guilds.execute(pid);
            assertEq(guilds.treasuryOf(gA), 1e18);
        }
    }

    /// @dev A proposal created in epoch E is usable through the last second of epoch E+1 and not
    ///      one second longer.
    function testFuzz_proposalExpiryBoundary(uint32 createOffset, uint32 checkOffset) public {
        join(erin, gA);
        uint256 created = START + 3 * EPOCH + bound(createOffset, 0, EPOCH - 1);
        vm.warp(created);
        uint256 pid = proposeAttack(alice, 5, 0, 1);
        uint256 checkAt = created + bound(checkOffset, 0, 3 * EPOCH);
        vm.warp(checkAt);
        bool expired = checkAt >= START + 5 * EPOCH;
        assertEq(guilds.isExpired(pid), expired);
        if (expired) {
            vm.prank(erin);
            vm.expectRevert(Guilds.ProposalExpired.selector);
            guilds.vote(pid, true);
        } else {
            voteYes(erin, pid);
            assertTrue(guilds.isApproved(pid));
        }
    }

    /// @dev The member count at any instant equals the number of players whose stints cover it.
    function testFuzz_memberCountAtAgreesWithStints(uint256 seed) public {
        address[4] memory players = [erin, frank, outsider, alice];
        uint256[] memory times = new uint256[](12);
        uint256 t = START;
        for (uint256 i; i < 12; ++i) {
            seed = uint256(keccak256(abi.encode(seed, i)));
            t += seed % 4 == 0 ? 0 : (seed % 5000);
            vm.warp(t);
            address who = players[(seed >> 8) % 4];
            if (guilds.guildOf(who) == gA) {
                vm.prank(who);
                guilds.leave();
            } else if (guilds.guildOf(who) == 0) {
                join(who, gA);
            }
            times[i] = t;
        }
        for (uint256 i; i < 12; ++i) {
            for (uint256 d; d < 2; ++d) {
                uint256 at = times[i] - d;
                uint256 fromStints;
                for (uint256 p; p < 4; ++p) {
                    if (guilds.wasMemberAt(gA, players[p], at)) fromStints += 1;
                }
                assertEq(guilds.memberCountAt(gA, at), fromStints, "count and stints disagree");
            }
        }
        assertEq(guilds.memberCountAt(gA, block.timestamp), guilds.memberCountOf(gA));
    }

    function test_joinGuildZeroReverts() public {
        vm.prank(erin);
        vm.expectRevert(Guilds.NoSuchGuild.selector);
        guilds.join(0);
    }

    function test_nameOfExactlyThirtyTwoBytesIsAccepted() public {
        vm.prank(erin);
        uint256 id = guilds.found("abcdefghijklmnopqrstuvwxyz012345");
        (string memory name,,,) = guilds.getGuild(id);
        assertEq(bytes(name).length, 32);
        vm.prank(frank);
        vm.expectRevert(Guilds.InvalidName.selector);
        guilds.found("abcdefghijklmnopqrstuvwxyz0123456");
    }

    function test_executeExpiredPayoutReverts() public {
        vm.prank(erin);
        guilds.deposit(gA, 1e18);
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, alice, 1e18, 0, 0, 0);
        assertTrue(guilds.isApproved(pid));
        warpToEpoch(2);
        vm.expectRevert(Guilds.ProposalExpired.selector);
        guilds.execute(pid);
        assertEq(guilds.treasuryOf(gA), 1e18);
    }

    function test_expelExecutesOnlyOnceAndNotAfterTheTargetLeft() public {
        join(erin, gA);
        join(frank, gA);
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.Expel, erin, 0, 0, 0, 0);
        voteYes(frank, pid);
        // Erin leaves on their own first: the expel then has nobody to remove.
        vm.prank(erin);
        guilds.leave();
        vm.expectRevert(Guilds.NotMember.selector);
        guilds.execute(pid);
        // Erin rejoins; the still-approved expel removes them again.
        join(erin, gA);
        guilds.execute(pid);
        assertEq(guilds.guildOf(erin), 0);
        vm.expectRevert(Guilds.ProposalAlreadyExecuted.selector);
        guilds.execute(pid);
    }

    function test_memberWhoLeftAndRejoinedCannotVoteOnOlderProposal() public {
        join(erin, gA);
        join(frank, gA);
        uint256 pid = proposeAttack(alice, 5, 0, 1);
        vm.prank(erin);
        guilds.leave();
        join(erin, gA);
        vm.prank(erin);
        vm.expectRevert(Guilds.NotEligibleVoter.selector);
        guilds.vote(pid, true);
        // Frank's vote makes two of the three counted at creation.
        voteYes(frank, pid);
        assertTrue(guilds.isApproved(pid));
    }

    function test_membersLeavingAfterCreationStayInTheDenominator() public {
        join(erin, gA);
        join(frank, gA);
        join(outsider, gA);
        buy(alice, 1);
        uint256 pid = proposeAttack(alice, 5, 0, 1); // 1 of 4
        vm.prank(erin);
        guilds.leave();
        vm.prank(frank);
        guilds.leave();
        // Only alice and outsider remain; outsider's yes makes 2 of 4, still no majority.
        voteYes(outsider, pid);
        assertFalse(guilds.isApproved(pid));
        vm.expectRevert(Guilds.ProposalNotApproved.selector);
        realm.declareAttack(pid);
    }

    function test_joinAndLeaveInTheSameSecond() public {
        vm.warp(START + 10);
        join(erin, gA);
        vm.prank(erin);
        guilds.leave();
        assertFalse(guilds.wasMemberAt(gA, erin, START + 10));
        assertEq(guilds.memberCountAt(gA, START + 10), 1);
        assertEq(guilds.stintCount(gA, erin), 1);
        Guilds.Stint memory s = guilds.stintAt(gA, erin, 0);
        assertEq(s.joinedAt, START + 10);
        assertEq(s.leftAt, START + 10);
    }

    function test_proposalLookupsRejectUnknownIds() public {
        vm.expectRevert(Guilds.NoSuchProposal.selector);
        guilds.isApproved(0);
        vm.expectRevert(Guilds.NoSuchProposal.selector);
        guilds.isExpired(1);
        vm.prank(alice);
        vm.expectRevert(Guilds.NoSuchProposal.selector);
        guilds.vote(1, true);
        vm.prank(address(realm));
        vm.expectRevert(Guilds.NoSuchProposal.selector);
        guilds.consume(1);
    }

    function test_pactProposalMustNameAnExistingOtherGuild() public {
        vm.startPrank(alice);
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Pact, address(diplomacy), 1, 0, 3, 0);
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Pact, address(diplomacy), 1, gA, 3, 0);
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Pact, address(diplomacy), 1, gB, 0, 0); // zero epochs
        vm.stopPrank();
    }

    function test_guildsConstructorRejectsZeroToken() public {
        vm.expectRevert(Guilds.ZeroAddress.selector);
        new Guilds(IERC20(address(0)), EPOCH);
    }

    // ============================================================ Realm

    /// @dev Whatever the forces, resolution never creates troops, the unique largest force wins,
    ///      a larger force always keeps at least as many survivors as a smaller one, an unopposed
    ///      attacker loses nothing, and a held tile is never left without a garrison.
    function testFuzz_resolutionProperties(uint16 defenseSeed, uint16 s1, uint16 s2, uint16 s3) public {
        uint256 defense = bound(defenseSeed, 0, 400);
        uint256[3] memory forces = [bound(s1, 0, 400), bound(s2, 0, 400), bound(s3, 0, 400)];
        if (forces[0] + forces[1] + forces[2] == 0) forces[0] = 1;
        address[3] memory attackers = [bob, carol, dave];
        uint256[3] memory guildIds = [gB, gC, gD];

        if (defense != 0) capture(alice, 7, defense);
        uint256 total = defense;
        for (uint256 i; i < 3; ++i) {
            if (forces[i] == 0) continue;
            buy(attackers[i], forces[i]);
            attackNow(attackers[i], 7, defense == 0 ? 0 : gA, forces[i]);
            total += forces[i];
        }
        nextEpoch();
        realm.settle();

        // Who should hold the tile.
        uint256 best = defense;
        uint256 bestIdx = 3; // 3 = holder
        bool unique = true;
        for (uint256 i; i < 3; ++i) {
            if (forces[i] > best) {
                best = forces[i];
                bestIdx = i;
                unique = true;
            } else if (forces[i] == best && forces[i] != 0) {
                unique = false;
            }
        }
        (uint256 holder, uint256 garrison) = realm.tile(7);
        if (bestIdx == 3 || !unique) {
            assertEq(holder, defense == 0 ? 0 : gA, "holder keeps the tile on a tie or when largest");
        } else {
            assertEq(holder, guildIds[bestIdx], "the unique largest attacker takes the tile");
        }
        if (holder != 0) assertGe(garrison, 1, "held tile has a garrison");
        else assertEq(garrison, 0);

        // Survivors per participant.
        uint256 holderSurvivors = defense == 0 ? 0 : (holder == gA ? garrison : realm.reserveOf(gA));
        uint256 alive = holderSurvivors;
        assertLe(holderSurvivors, defense, "holder cannot gain troops");
        uint256[3] memory survivors;
        for (uint256 i; i < 3; ++i) {
            survivors[i] = holder == guildIds[i] ? garrison : realm.reserveOf(guildIds[i]);
            assertLe(survivors[i], forces[i], "attacker cannot gain troops");
            alive += survivors[i];
        }
        assertLe(alive, total, "resolution never creates troops");
        if (total == best && bestIdx != 3) assertEq(alive, total, "an unopposed attacker loses nothing");
        // A larger force never ends with fewer survivors than a smaller one.
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                if (forces[i] > forces[j]) assertGe(survivors[i], survivors[j], "larger force lost more");
            }
            if (forces[i] > defense) assertGe(survivors[i], holderSurvivors);
            if (defense > forces[i]) assertGe(holderSurvivors, survivors[i]);
            if (forces[i] != 0) assertGe(survivors[i], 1, "every participant keeps at least one troop");
        }
    }

    /// @dev Fee and income always add up to the price paid, for any fee rate up to 100%.
    function testFuzz_feeSplitIsExact(uint16 feeSeed, uint32 troopsSeed) public {
        uint256 bps = bound(feeSeed, 0, 10_000);
        uint256 troops = bound(troopsSeed, 1, 500_000);
        Realm r = new Realm(IERC20(address(token)), guilds, EPOCH, SEASON, PRICE, bps);
        vm.prank(alice);
        token.approve(address(r), type(uint256).max);
        vm.prank(alice);
        uint256 cost = r.buyTroops(troops);
        uint256 fee = token.balanceOf(address(r.season()));
        assertEq(cost, troops * PRICE);
        assertEq(fee, cost * bps / 10_000);
        assertEq(token.balanceOf(address(r)), cost - fee);
        assertEq(r.incomePool(0), cost - fee);
        assertEq(r.season().prizePool(0), fee);
        assertEq(r.reserveOf(gA), troops);
    }

    /// @dev Income is split equally per tile between holders and nothing leaks: what the holders
    ///      are owed plus the carried dust equals what was paid in.
    function testFuzz_incomeSplitsEquallyPerTile(uint8 tilesASeed, uint8 tilesBSeed, uint32 purchaseSeed) public {
        uint256 tilesA = bound(tilesASeed, 0, 4);
        uint256 tilesB = bound(tilesBSeed, 0, 4);
        uint256 purchase = bound(purchaseSeed, 1, 100_000);
        if (tilesA != 0) buy(alice, tilesA);
        if (tilesB != 0) buy(bob, tilesB);
        for (uint256 i; i < tilesA; ++i) {
            attackNow(alice, i, 0, 1);
        }
        for (uint256 i; i < tilesB; ++i) {
            attackNow(bob, 10 + i, 0, 1);
        }
        nextEpoch();
        realm.settle(); // captures land; epoch 0 income is carried (no holders yet)
        uint256 carried = realm.incomeCarry();
        buy(carol, purchase);
        uint256 pool = carried + realm.incomePool(1);
        nextEpoch();
        realm.settle();
        uint256 held = tilesA + tilesB;
        uint256 pA = realm.pendingIncome(gA);
        uint256 pB = realm.pendingIncome(gB);
        assertEq(pA + pB + realm.incomeCarry(), pool, "income leaked");
        if (held == 0) {
            assertEq(realm.incomeCarry(), pool);
            return;
        }
        assertLt(realm.incomeCarry(), held, "carry is only rounding dust");
        if (tilesA != 0 && tilesB != 0) assertEq(pA / tilesA, pB / tilesB, "unequal per-tile income");
        if (tilesA == 0) assertEq(pA, 0);
        if (tilesB == 0) assertEq(pB, 0);
        assertEq(token.balanceOf(address(realm)), pA + pB + realm.incomeCarry());
    }

    function test_attackOnLastTileWorksAndBeyondIsRejected() public {
        buy(alice, 2);
        attackNow(alice, 143, 0, 1);
        uint256 bad = proposeAttack(alice, 144, 0, 1);
        vm.expectRevert(Realm.InvalidTile.selector);
        realm.declareAttack(bad);
        uint256 huge = proposeAttack(alice, type(uint256).max, 0, 1);
        vm.expectRevert(Realm.InvalidTile.selector);
        realm.declareAttack(huge);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(143), gA);
    }

    function test_attackCommitsExactlyTheReserve() public {
        buy(alice, 7);
        attackNow(alice, 3, 0, 7);
        assertEq(realm.reserveOf(gA), 0);
        uint256 more = proposeAttack(alice, 4, 0, 1);
        vm.expectRevert(abi.encodeWithSelector(Realm.InsufficientTroops.selector, 0, 1));
        realm.declareAttack(more);
    }

    function test_buyTroopsOverflowReverts() public {
        vm.prank(alice);
        vm.expectRevert();
        realm.buyTroops(type(uint256).max);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, FUNDS, FUNDS + PRICE));
        realm.buyTroops(FUNDS / PRICE + 1);
    }

    function test_settleExactlyAtTheEpochBoundary() public {
        vm.warp(START + EPOCH - 1);
        vm.expectRevert(Realm.EpochNotEnded.selector);
        realm.settle();
        vm.warp(START + EPOCH);
        realm.settle();
        assertEq(realm.settlePending(5), 0);
    }

    function test_threeWayTieForLargestKeepsTheHolder() public {
        capture(alice, 7, 6);
        buy(bob, 6);
        buy(carol, 6);
        buy(dave, 2);
        attackNow(bob, 7, gA, 6);
        attackNow(carol, 7, gA, 6);
        attackNow(dave, 7, gA, 2);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(7), gA);
        // total 20: 6-troop forces lose 6*14/20 = 4, the 2-troop force loses 2*18/20 = 1.
        assertEq(tileGarrison(7), 2);
        assertEq(realm.reserveOf(gB), 2);
        assertEq(realm.reserveOf(gC), 2);
        assertEq(realm.reserveOf(gD), 1);
    }

    function test_smallerThirdPartyDoesNotBreakAnAttackersWin() public {
        capture(alice, 7, 5);
        buy(bob, 9);
        buy(carol, 1);
        attackNow(bob, 7, gA, 9);
        attackNow(carol, 7, gA, 1);
        nextEpoch();
        realm.settle();
        // total 15: Beta loses 9*6/15 = 3, Alpha loses 5*10/15 = 3, Gamma loses 1*14/15 = 0.
        assertEq(tileHolder(7), gB);
        assertEq(tileGarrison(7), 6);
        assertEq(realm.reserveOf(gA), 2);
        assertEq(realm.reserveOf(gC), 1);
    }

    function test_oneTroopAgainstOneTroopHolderKeepsOneEach() public {
        capture(alice, 7, 1);
        buy(bob, 1);
        attackNow(bob, 7, gA, 1);
        nextEpoch();
        realm.settle();
        // total 2: each loses 1*1/2 = 0.
        assertEq(tileHolder(7), gA);
        assertEq(tileGarrison(7), 1);
        assertEq(realm.reserveOf(gB), 1);
    }

    /// @dev Alpha holds two tiles that the scan meets first and last, so it is pushed out of the
    ///      top three and met again; three guilds tie on three tiles and rank by age.
    function test_standingsRankFiveGuildsWithTiesByAgeAndReencounter() public {
        uint256 gE = found(erin, "Eps");
        buy(alice, 2);
        buy(bob, 3);
        buy(carol, 3);
        buy(dave, 3);
        buy(erin, 1);
        attackNow(alice, 0, 0, 1);
        attackNow(alice, 10, 0, 1);
        for (uint256 t = 1; t <= 3; ++t) {
            attackNow(bob, t, 0, 1);
            attackNow(carol, 3 + t, 0, 1);
            attackNow(dave, 6 + t, 0, 1);
        }
        attackNow(erin, 11, 0, 1);
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        (uint256[3] memory ids, uint256[3] memory tiles,) = realm.standingsOf(0);
        assertEq(ids[0], gB);
        assertEq(ids[1], gC);
        assertEq(ids[2], gD);
        assertEq(tiles[0], 3);
        assertEq(tiles[1], 3);
        assertEq(tiles[2], 3);
        assertEq(realm.tilesHeldBy(gA), 2);
        assertEq(realm.tilesHeldBy(gE), 1);
    }

    function test_collectIncomeForUnknownGuildMovesNothing() public {
        uint256 bal = token.balanceOf(address(realm));
        assertEq(realm.collectIncome(99), 0);
        assertEq(realm.collectIncome(0), 0);
        assertEq(token.balanceOf(address(realm)), bal);
    }

    function test_realmRejectsGuildsBoundToAnotherToken() public {
        LaunchToken other = new LaunchToken();
        Guilds g2 = new Guilds(IERC20(address(other)), EPOCH);
        vm.expectRevert(Realm.InvalidParameters.selector);
        new Realm(IERC20(address(token)), g2, EPOCH, SEASON, PRICE, FEE_BPS);
        vm.expectRevert(Realm.ZeroAddress.selector);
        new Realm(IERC20(address(0)), guilds, EPOCH, SEASON, PRICE, FEE_BPS);
        vm.expectRevert(Realm.InvalidParameters.selector);
        new Realm(IERC20(address(token)), guilds, EPOCH, 0, PRICE, FEE_BPS);
    }

    function test_hundredPercentFeeSendsEverythingToSeason() public {
        Realm r = new Realm(IERC20(address(token)), guilds, EPOCH, SEASON, PRICE, 10_000);
        vm.prank(alice);
        token.approve(address(r), type(uint256).max);
        vm.prank(alice);
        r.buyTroops(3);
        assertEq(token.balanceOf(address(r)), 0);
        assertEq(token.balanceOf(address(r.season())), 3e18);
        assertEq(r.incomePool(0), 0);
    }

    // ======================================================== Diplomacy

    /// @dev A pact of N epochs signed in epoch S is broken by an attack in any epoch up to S+N-1
    ///      and merely expires on an attack from S+N onwards.
    function testFuzz_pactWindowBoundary(uint8 epochsSeed, uint8 delaySeed) public {
        uint256 epochs = bound(epochsSeed, 1, 20);
        uint256 delay = bound(delaySeed, 0, 25);
        capture(bob, 7, 10); // Beta holds tile 7; we are now in epoch 1
        vm.prank(erin);
        guilds.deposit(gA, 10e18);
        vm.prank(erin);
        guilds.deposit(gB, 20e18);
        uint256 pa = proposePact(alice, gB, 10e18, epochs);
        uint256 pb = proposePact(bob, gA, 20e18, epochs);
        uint256 pactId = diplomacy.sign(pa, pb);
        assertEq(diplomacy.getPact(pactId).endEpoch, epochs); // 1 + epochs - 1
        warpToEpoch(1 + delay);
        buy(alice, 1);
        attackNow(alice, 7, gB, 1);
        Diplomacy.Pact memory p = diplomacy.getPact(pactId);
        if (delay < epochs) {
            assertEq(uint256(p.status), uint256(Diplomacy.Status.Broken));
            assertEq(guilds.treasuryOf(gB), 30e18, "victim gets both bonds");
            assertEq(guilds.treasuryOf(gA), 0);
            assertEq(diplomacy.betrayals(gA, realm.seasonOfEpoch(1 + delay)), 1);
        } else {
            assertEq(uint256(p.status), uint256(Diplomacy.Status.Expired));
            assertEq(guilds.treasuryOf(gA), 10e18);
            assertEq(guilds.treasuryOf(gB), 20e18);
            assertEq(diplomacy.betrayals(gA, realm.seasonOfEpoch(1 + delay)), 0);
        }
        assertEq(token.balanceOf(address(diplomacy)), 0);
        assertEq(diplomacy.activePactBetween(gA, gB), 0);
    }

    function test_signAcceptsProposalsInEitherOrder() public {
        vm.prank(erin);
        guilds.deposit(gA, 5e18);
        vm.prank(erin);
        guilds.deposit(gB, 5e18);
        uint256 pa = proposePact(alice, gB, 1e18, 2);
        uint256 pb = proposePact(bob, gA, 2e18, 2);
        uint256 id = diplomacy.sign(pb, pa);
        Diplomacy.Pact memory p = diplomacy.getPact(id);
        assertEq(p.guildA, gB);
        assertEq(p.bondA, 2e18);
        assertEq(p.guildB, gA);
        assertEq(p.bondB, 1e18);
        // The same proposals cannot back a second pact.
        warpToEpoch(2);
        diplomacy.expire(id);
        vm.expectRevert(Guilds.ProposalAlreadyExecuted.selector);
        diplomacy.sign(pa, pb);
    }

    function test_signRejectsAConsumedProposal() public {
        vm.prank(erin);
        guilds.deposit(gA, 5e18);
        vm.prank(erin);
        guilds.deposit(gB, 5e18);
        vm.prank(erin);
        guilds.deposit(gC, 5e18);
        uint256 pa = proposePact(alice, gB, 1e18, 1);
        uint256 pb = proposePact(bob, gA, 1e18, 1);
        diplomacy.sign(pa, pb);
        warpToEpoch(1);
        diplomacy.expire(1);
        uint256 pb2 = proposePact(bob, gA, 1e18, 1);
        vm.expectRevert(Guilds.ProposalAlreadyExecuted.selector);
        diplomacy.sign(pa, pb2);
        // A pact with a third guild while one with Beta exists is fine.
        uint256 pa3 = proposePact(alice, gC, 1e18, 1);
        uint256 pc = proposePact(carol, gA, 1e18, 1);
        diplomacy.sign(pa3, pc);
    }

    function test_singleEpochPactBrokenSameEpochExpiredNext() public {
        capture(bob, 7, 10);
        vm.prank(erin);
        guilds.deposit(gA, 1e18);
        vm.prank(erin);
        guilds.deposit(gB, 1e18);
        uint256 pa = proposePact(alice, gB, 1e18, 1);
        uint256 pb = proposePact(bob, gA, 1e18, 1);
        uint256 id = diplomacy.sign(pa, pb);
        vm.expectRevert(Diplomacy.PactNotEnded.selector);
        diplomacy.expire(id);
        nextEpoch();
        buy(alice, 1);
        attackNow(alice, 7, gB, 1);
        assertEq(uint256(diplomacy.getPact(id).status), uint256(Diplomacy.Status.Expired));
        assertEq(guilds.treasuryOf(gA), 1e18);
        vm.expectRevert(Diplomacy.PactNotActive.selector);
        diplomacy.expire(id);
    }

    function test_expireByOutsiderReturnsBondsToTreasuriesNotToCaller() public {
        vm.prank(erin);
        guilds.deposit(gA, 3e18);
        vm.prank(erin);
        guilds.deposit(gB, 4e18);
        uint256 pa = proposePact(alice, gB, 3e18, 1);
        uint256 pb = proposePact(bob, gA, 4e18, 1);
        uint256 id = diplomacy.sign(pa, pb);
        nextEpoch();
        vm.prank(outsider);
        diplomacy.expire(id);
        assertEq(guilds.treasuryOf(gA), 3e18);
        assertEq(guilds.treasuryOf(gB), 4e18);
        assertEq(token.balanceOf(outsider), FUNDS);
    }

    function test_pactLookupRejectsUnknownIds() public {
        vm.expectRevert(Diplomacy.NoSuchPact.selector);
        diplomacy.getPact(0);
        vm.expectRevert(Diplomacy.NoSuchPact.selector);
        diplomacy.getPact(1);
        assertEq(diplomacy.activePactBetween(gA, gB), 0);
    }

    function test_betrayalOfOnePartnerLeavesOtherPactsIntact() public {
        capture(bob, 7, 10);
        vm.prank(erin);
        guilds.deposit(gA, 4e18);
        vm.prank(erin);
        guilds.deposit(gB, 2e18);
        vm.prank(erin);
        guilds.deposit(gC, 2e18);
        uint256 pa = proposePact(alice, gB, 2e18, 5);
        uint256 pb = proposePact(bob, gA, 2e18, 5);
        uint256 withB = diplomacy.sign(pa, pb);
        uint256 pa2 = proposePact(alice, gC, 2e18, 5);
        uint256 pc = proposePact(carol, gA, 2e18, 5);
        uint256 withC = diplomacy.sign(pa2, pc);
        buy(alice, 1);
        attackNow(alice, 7, gB, 1);
        assertEq(uint256(diplomacy.getPact(withB).status), uint256(Diplomacy.Status.Broken));
        assertEq(uint256(diplomacy.getPact(withC).status), uint256(Diplomacy.Status.Active));
        assertEq(token.balanceOf(address(diplomacy)), 4e18);
        assertEq(guilds.treasuryOf(gB), 4e18);
    }

    // =========================================================== Season

    /// @dev Prize allocation never exceeds the pool and every entitled member can claim.
    function testFuzz_seasonAllocationAndClaims(uint8 extraA, uint8 extraB, uint32 troopsSeed) public {
        uint256 nA = 1 + bound(extraA, 0, 2);
        uint256 nB = 1 + bound(extraB, 0, 1);
        address[2] memory extrasA = [erin, frank];
        if (nA > 1) join(erin, gA);
        if (nA > 2) join(frank, gA);
        if (nB > 1) join(outsider, gB);
        uint256 troops = bound(troopsSeed, 3, 50_000);
        buy(alice, troops);
        buy(bob, 2);
        buy(carol, 1);
        for (uint256 t; t < 3; ++t) {
            uint256 pid = proposeAttack(alice, t, 0, 1);
            if (nA > 1) voteYes(erin, pid);
            if (nA > 2) voteYes(frank, pid);
            realm.declareAttack(pid);
        }
        for (uint256 t = 3; t < 5; ++t) {
            uint256 pid = proposeAttack(bob, t, 0, 1);
            if (nB > 1) voteYes(outsider, pid);
            realm.declareAttack(pid);
        }
        attackNow(carol, 5, 0, 1);
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        uint256 pool = season.prizePool(0);
        season.close(0);
        Season.Result memory r = season.getResult(0);
        assertEq(r.guildIds[0], gA);
        assertEq(r.guildIds[1], gB);
        assertEq(r.guildIds[2], gC);
        assertEq(r.memberCount[0], nA);
        assertEq(r.memberCount[1], nB);
        assertEq(r.memberCount[2], 1);
        uint256 allocated = r.guildPrize[0] + r.guildPrize[1] + r.guildPrize[2];
        assertEq(allocated + r.rollover, pool);
        assertLe(r.guildPrize[0], pool * 50 / 100);
        assertLe(r.guildPrize[1], pool * 30 / 100);
        assertLe(r.guildPrize[2], pool * 20 / 100);
        assertEq(r.perMember[0] * nA, r.guildPrize[0]);
        // Everyone entitled claims exactly perMember; afterwards Season holds only the rollover.
        vm.prank(alice);
        (uint256 got,) = season.claim(0, gA);
        assertEq(got, r.perMember[0]);
        for (uint256 i; i + 1 < nA; ++i) {
            vm.prank(extrasA[i]);
            (got,) = season.claim(0, gA);
            assertEq(got, r.perMember[0]);
        }
        vm.prank(bob);
        (got,) = season.claim(0, gB);
        assertEq(got, r.perMember[1]);
        if (nB > 1) {
            vm.prank(outsider);
            (got,) = season.claim(0, gB);
            assertEq(got, r.perMember[1]);
        }
        vm.prank(carol);
        (got,) = season.claim(0, gC);
        assertEq(got, r.perMember[2]);
        assertEq(token.balanceOf(address(season)), r.rollover);
        assertEq(season.prizePool(1), r.rollover);
        assertEq(banners.totalSupply(), nA + nB + 1);
    }

    function test_expelledBeforeSeasonEndCannotClaim() public {
        join(erin, gA);
        join(frank, gA);
        buy(alice, 1);
        uint256 pid = proposeAttack(alice, 0, 0, 1);
        voteYes(erin, pid);
        realm.declareAttack(pid);
        vm.warp(START + SEASON - 1);
        vm.prank(alice);
        uint256 expel = guilds.propose(Guilds.Kind.Expel, frank, 0, 0, 0, 0);
        voteYes(erin, expel);
        guilds.execute(expel);
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        assertEq(season.getResult(0).memberCount[0], 2);
        vm.prank(frank);
        vm.expectRevert(Season.NotMemberAtSeasonEnd.selector);
        season.claim(0, gA);
        vm.prank(erin);
        (uint256 got,) = season.claim(0, gA);
        assertEq(got, season.getResult(0).perMember[0]);
    }

    function test_zeroPoolSeasonStillAwardsBanners() public {
        Realm r = new Realm(IERC20(address(token)), guilds, EPOCH, SEASON, PRICE, 0);
        Season s = r.season();
        vm.prank(alice);
        token.approve(address(r), type(uint256).max);
        vm.prank(alice);
        r.buyTroops(1);
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.Attack, address(r), 0, 0, 0, 1);
        r.declareAttack(pid);
        warpToEpoch(EPOCHS_PER_SEASON);
        r.settlePending(EPOCHS_PER_SEASON);
        s.close(0);
        assertEq(s.getResult(0).pool, 0);
        vm.prank(alice);
        (uint256 amount, uint256 tokenId) = s.claim(0, gA);
        assertEq(amount, 0);
        assertEq(s.banners().ownerOf(tokenId), alice);
        assertEq(s.banners().bannerOf(tokenId).rank, 1);
    }

    function test_claimOnWrongSeasonOrGuildIdZero() public {
        capture(alice, 0, 1);
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        vm.prank(alice);
        vm.expectRevert(Season.SeasonNotClosed.selector);
        season.claim(1, gA);
        vm.prank(alice);
        vm.expectRevert(Season.NotAWinner.selector);
        season.claim(0, 0);
    }

    function test_peaceBannerRejectsGuildZeroAndUnknownSeasonState() public {
        warpToEpoch(EPOCHS_PER_SEASON);
        vm.expectRevert(Season.GuildNotEligible.selector);
        season.mintPeaceBanner(0, 0);
        vm.expectRevert(Season.SeasonNotEnded.selector);
        season.mintPeaceBanner(1, gA);
        // No settlement is needed for a peace banner, only the calendar.
        uint256 id = season.mintPeaceBanner(0, gA);
        assertEq(banners.ownerOf(id), address(guilds));
    }

    function test_peaceBannerCannotLeaveTheGuildsContract() public {
        warpToEpoch(EPOCHS_PER_SEASON);
        uint256 id = season.mintPeaceBanner(0, gA);
        vm.prank(alice);
        vm.expectRevert(Banners.NotAuthorized.selector);
        banners.transferFrom(address(guilds), alice, id);
        vm.prank(alice);
        vm.expectRevert(Banners.NotAuthorized.selector);
        banners.approve(alice, id);
        assertEq(banners.balanceOf(address(guilds)), 1);
    }

    function test_seasonFeesOfLaggedEpochsBookToTheirCalendarSeason() public {
        // A purchase in season 1 while season 0 is still unsettled books to season 1.
        buy(alice, 10);
        warpToEpoch(EPOCHS_PER_SEASON + 1);
        buy(alice, 10);
        assertEq(season.prizePool(0), 0.5e18);
        assertEq(season.prizePool(1), 0.5e18);
        realm.settlePending(EPOCHS_PER_SEASON + 1);
        season.close(0);
        assertEq(season.getResult(0).pool, 0.5e18);
    }

    // ========================================================== Banners

    function test_bannerTransferFailurePaths() public {
        capture(alice, 0, 1);
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        vm.prank(alice);
        (, uint256 id) = season.claim(0, gA);

        vm.prank(alice);
        vm.expectRevert(Banners.WrongFrom.selector);
        banners.transferFrom(bob, carol, id);
        vm.prank(alice);
        vm.expectRevert(Banners.ZeroAddress.selector);
        banners.transferFrom(alice, address(0), id);
        vm.prank(bob);
        vm.expectRevert(Banners.NotAuthorized.selector);
        banners.approve(bob, id);
        vm.expectRevert(Banners.NoSuchToken.selector);
        banners.transferFrom(alice, bob, id + 1);
        vm.expectRevert(Banners.ZeroAddress.selector);
        banners.balanceOf(address(0));
        vm.expectRevert(Banners.NoSuchToken.selector);
        banners.getApproved(id + 1);
        vm.expectRevert(Banners.NoSuchToken.selector);
        banners.tokenURI(id + 1);
        vm.expectRevert(Banners.NoSuchToken.selector);
        banners.bannerOf(0);
        assertFalse(banners.supportsInterface(0xffffffff));
        assertTrue(banners.supportsInterface(0x01ffc9a7));
        assertTrue(banners.supportsInterface(0x5b5e139f));

        // Safe transfers check the receiver.
        BadReceiver bad = new BadReceiver();
        vm.prank(alice);
        vm.expectRevert(Banners.UnsafeRecipient.selector);
        banners.safeTransferFrom(alice, address(bad), id);
        vm.prank(alice);
        vm.expectRevert();
        banners.safeTransferFrom(alice, address(guilds), id); // no receiver hook at all
        GoodReceiver good = new GoodReceiver();
        vm.prank(alice);
        banners.safeTransferFrom(alice, address(good), id, "x");
        assertEq(banners.ownerOf(id), address(good));
        assertEq(banners.balanceOf(alice), 0);
        assertEq(banners.balanceOf(address(good)), 1);
    }

    function test_operatorApprovalsWork() public {
        capture(alice, 0, 1);
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        vm.prank(alice);
        (, uint256 id) = season.claim(0, gA);
        vm.prank(alice);
        banners.setApprovalForAll(bob, true);
        assertTrue(banners.isApprovedForAll(alice, bob));
        vm.prank(bob);
        banners.approve(carol, id); // an operator may approve
        assertEq(banners.getApproved(id), carol);
        vm.prank(bob);
        banners.transferFrom(alice, dave, id);
        assertEq(banners.ownerOf(id), dave);
        assertEq(banners.getApproved(id), address(0), "approval cleared on transfer");
        vm.prank(alice);
        banners.setApprovalForAll(bob, false);
        assertFalse(banners.isApprovedForAll(alice, bob));
        vm.prank(bob);
        vm.expectRevert(Banners.NotAuthorized.selector);
        banners.transferFrom(dave, bob, id);
    }

    function test_freshBannersTrustOnlyItsDeployerAndRejectZeroRecipient() public {
        Banners fresh = new Banners();
        assertEq(fresh.minter(), address(this));
        vm.expectRevert(Banners.ZeroAddress.selector);
        fresh.mint(address(0), 0, 1, Banners.BannerKind.Peace, 0);
        uint256 id = fresh.mint(alice, 3, 2, Banners.BannerKind.Peace, 0);
        assertEq(id, 1);
        assertEq(fresh.totalSupply(), 1);
        vm.prank(alice);
        vm.expectRevert(Banners.NotMinter.selector);
        fresh.mint(alice, 3, 2, Banners.BannerKind.Peace, 0);
        string memory uri = fresh.tokenURI(1);
        assertEq(
            uri,
            string.concat(
                "data:application/json;utf8,{\"name\":\"Pact Banner #1\",\"description\":\"Pacts season trophy.\",",
                "\"attributes\":[{\"trait_type\":\"Kind\",\"value\":\"Peace\"},{\"trait_type\":\"Season\",\"value\":3},",
                "{\"trait_type\":\"Guild\",\"value\":2},{\"trait_type\":\"Rank\",\"value\":0}]}"
            )
        );
    }

    // ====================================================== LaunchToken

    function test_tokenRejectsZeroSpenderAndOverdrawnTransferFrom() public {
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, FUNDS, FUNDS + 1));
        token.transferFrom(alice, bob, FUNDS + 1);
        vm.prank(bob);
        vm.expectRevert(LaunchToken.ZeroAddress.selector);
        token.transferFrom(alice, address(0), 1);
    }

    function testFuzz_transferFromNeverExceedsAllowanceOrBalance(uint256 allowance, uint256 amount) public {
        allowance = bound(allowance, 0, type(uint256).max - 1); // finite allowance
        amount = bound(amount, 0, 2 * FUNDS);
        vm.prank(alice);
        token.approve(bob, allowance);
        vm.prank(bob);
        if (amount > allowance) {
            vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientAllowance.selector, allowance, amount));
            token.transferFrom(alice, carol, amount);
        } else if (amount > FUNDS) {
            vm.expectRevert(abi.encodeWithSelector(LaunchToken.InsufficientBalance.selector, FUNDS, amount));
            token.transferFrom(alice, carol, amount);
        } else {
            token.transferFrom(alice, carol, amount);
            assertEq(token.allowance(alice, bob), allowance - amount);
            assertEq(token.balanceOf(carol), FUNDS + amount);
            assertEq(token.balanceOf(alice), FUNDS - amount);
        }
        assertEq(token.totalSupply(), 10 ** 27);
    }

    // ======================================================= no admin

    function test_ownerReferenceIsUnusedNothingReactsToTheDeployer() public {
        // The deployer of every contract is this test; it holds no power anywhere.
        address[6] memory targets =
            [address(token), address(guilds), address(realm), address(diplomacy), address(season), address(banners)];
        string[6] memory sigs = [
            "owner()",
            "setTroopPrice(uint256)",
            "setFeeBps(uint256)",
            "setRealm(address)",
            "setMinter(address)",
            "rescue(address,uint256)"
        ];
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < sigs.length; ++j) {
                (bool ok,) = targets[i].call(abi.encodeWithSignature(sigs[j], address(this), uint256(1)));
                assertFalse(ok, sigs[j]);
            }
        }
        assertEq(banners.minter(), address(season));
        assertEq(address(diplomacy.realm()), address(realm));
        assertEq(address(season.realm()), address(realm));
    }
}
