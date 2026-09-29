// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";
import {Banners} from "../src/Banners.sol";

/// @dev Every token the game holds is owed to someone under the rules; nothing else can move it.
contract FundsSafetyTest is PactsBase {
    uint256 internal gA;
    uint256 internal gB;
    uint256 internal gC;

    function setUp() public override {
        super.setUp();
        gA = found(alice, "Alpha");
        join(dave, gA);
        gB = found(bob, "Beta");
        gC = found(carol, "Gamma");
    }

    /// @dev Contract balances match their internal accounting at every step of a full season.
    function test_contractBalancesMatchAccountingThroughAScenario() public {
        // Purchases and captures in epoch 0.
        buy(alice, 40);
        buy(bob, 30);
        buy(carol, 10);
        uint256 pid = proposeAttack(alice, 0, 0, 20);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        attackNow(bob, 1, 0, 15);
        attackNow(carol, 2, 0, 10);
        checkAccounting();

        nextEpoch();
        realm.settle();
        checkAccounting();

        // A pact between Alpha and Beta, funded from their tile income.
        buy(alice, 5); // more income for epoch 1
        nextEpoch();
        realm.settle();
        realm.collectIncome(gA);
        realm.collectIncome(gB);
        realm.collectIncome(gC);
        checkAccounting();
        uint256 pa = proposePact(alice, gB, 1e18, 3);
        voteYes(dave, pa);
        uint256 pb = proposePact(bob, gA, 1e18, 3);
        diplomacy.sign(pa, pb);
        checkAccounting();

        // Alpha betrays Beta: Beta's treasury receives both bonds.
        pid = proposeAttack(alice, 1, gB, 20);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        checkAccounting();
        nextEpoch();
        realm.settle();
        checkAccounting();

        // Beta pays part of its treasury out by vote.
        uint256 payout = guilds.treasuryOf(gB) / 2;
        vm.prank(bob);
        uint256 pay = guilds.propose(Guilds.Kind.Payout, bob, payout, 0, 0, 0);
        guilds.execute(pay);
        checkAccounting();

        // Season end, close and claims.
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        checkAccounting();
        Season.Result memory r = season.getResult(0);
        address[3] memory claimants = [alice, bob, carol];
        for (uint256 i; i < 3; ++i) {
            for (uint256 j; j < 3; ++j) {
                if (r.guildIds[i] == guilds.guildOf(claimants[j])) {
                    vm.prank(claimants[j]);
                    season.claim(0, r.guildIds[i]);
                }
            }
        }
        checkAccounting();
        // Everything that left the players is still inside the game or was paid back to a player.
        uint256 playersHold = token.balanceOf(alice) + token.balanceOf(bob) + token.balanceOf(carol)
            + token.balanceOf(dave) + token.balanceOf(erin) + token.balanceOf(frank) + token.balanceOf(outsider);
        uint256 gameHolds = token.balanceOf(address(realm)) + token.balanceOf(address(guilds))
            + token.balanceOf(address(diplomacy)) + token.balanceOf(address(season));
        assertEq(playersHold + gameHolds + token.balanceOf(address(this)), token.totalSupply());
    }

    function test_unauthorizedCallsCannotMoveFunds() public {
        buy(alice, 20);
        uint256 pid = proposeAttack(alice, 0, 0, 20);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        nextEpoch();
        realm.settle();
        buy(bob, 20);
        nextEpoch();
        realm.settle();
        realm.collectIncome(gA);
        vm.prank(erin);
        guilds.deposit(gB, 50e18);
        uint256 pa = proposePact(alice, gB, 1e18, 3);
        voteYes(dave, pa);
        uint256 pb = proposePact(bob, gA, 1e18, 3);
        diplomacy.sign(pa, pb);

        uint256 realmBal = token.balanceOf(address(realm));
        uint256 guildsBal = token.balanceOf(address(guilds));
        uint256 diplomacyBal = token.balanceOf(address(diplomacy));
        uint256 seasonBal = token.balanceOf(address(season));
        uint256 treasuryA = guilds.treasuryOf(gA);
        uint256 treasuryB = guilds.treasuryOf(gB);

        vm.startPrank(outsider);
        // Guilds: consume needs the named target; execute needs an approved local proposal.
        vm.expectRevert(Guilds.NotTarget.selector);
        guilds.consume(pa);
        vm.expectRevert(Guilds.NoSuchProposal.selector);
        guilds.execute(99);
        vm.expectRevert(Guilds.NotInGuild.selector);
        guilds.propose(Guilds.Kind.Payout, outsider, 1, 0, 0, 0);
        // A single member of a two-member guild cannot pay out alone.
        vm.stopPrank();
        vm.prank(dave);
        uint256 solo = guilds.propose(Guilds.Kind.Payout, dave, 1, 0, 0, 0);
        vm.expectRevert(Guilds.ProposalNotApproved.selector);
        guilds.execute(solo);
        vm.startPrank(outsider);
        // Diplomacy: only Realm reports attacks.
        vm.expectRevert(Diplomacy.NotRealm.selector);
        diplomacy.onAttack(gA, gB, 2);
        vm.expectRevert(Diplomacy.PactNotEnded.selector);
        diplomacy.expire(1);
        // Season: only Realm books fees; nothing to claim before close.
        vm.expectRevert(Season.NotRealm.selector);
        season.recordFee(0, 1);
        vm.expectRevert(Season.SeasonNotClosed.selector);
        season.claim(0, gA);
        vm.expectRevert(Season.SeasonNotEnded.selector);
        season.close(0);
        // Banners: only Season mints.
        vm.expectRevert(Banners.NotMinter.selector);
        banners.mint(outsider, 0, gA, Banners.BannerKind.Winner, 1);
        // Realm: income only ever flows into the guild's own treasury.
        realm.collectIncome(gA);
        vm.expectRevert(Realm.NotInGuild.selector);
        realm.buyTroops(1);
        vm.stopPrank();

        assertEq(token.balanceOf(address(realm)), realmBal);
        assertEq(token.balanceOf(address(guilds)), guildsBal);
        assertEq(token.balanceOf(address(diplomacy)), diplomacyBal);
        assertEq(token.balanceOf(address(season)), seasonBal);
        assertEq(guilds.treasuryOf(gA), treasuryA);
        assertEq(guilds.treasuryOf(gB), treasuryB);
        assertEq(token.balanceOf(outsider), FUNDS);
    }

    function test_noContractExposesAdminSelectors() public {
        address[5] memory targets =
            [address(realm), address(guilds), address(diplomacy), address(season), address(banners)];
        string[8] memory sigs = [
            "owner()",
            "transferOwnership(address)",
            "pause()",
            "unpause()",
            "withdraw(uint256)",
            "setFee(uint256)",
            "upgradeTo(address)",
            "initialize(address)"
        ];
        for (uint256 i; i < targets.length; ++i) {
            for (uint256 j; j < sigs.length; ++j) {
                (bool ok,) = targets[i].call(abi.encodeWithSignature(sigs[j], address(this), uint256(1)));
                assertFalse(ok, sigs[j]);
            }
        }
    }

    /// @dev Guilds holds exactly the treasuries, Diplomacy exactly the active bonds, Realm exactly the
    ///      income not yet collected, Season exactly the unclaimed prize money.
    function checkAccounting() internal view {
        uint256 treasuries;
        for (uint256 g = 1; g <= guilds.guildCount(); ++g) {
            treasuries += guilds.treasuryOf(g);
        }
        assertEq(token.balanceOf(address(guilds)), treasuries, "guilds balance");

        uint256 bonds;
        for (uint256 p = 1; p <= diplomacy.pactCount(); ++p) {
            Diplomacy.Pact memory pact = diplomacy.getPact(p);
            if (pact.status == Diplomacy.Status.Active) bonds += pact.bondA + pact.bondB;
        }
        assertEq(token.balanceOf(address(diplomacy)), bonds, "diplomacy balance");

        uint256 owed = realm.incomeCarry();
        for (uint256 g = 1; g <= guilds.guildCount(); ++g) {
            owed += realm.pendingIncome(g);
        }
        for (uint256 e = realm.settledEpochs(); e <= realm.currentEpoch(); ++e) {
            owed += realm.incomePool(e);
        }
        assertEq(token.balanceOf(address(realm)), owed, "realm balance");
    }
}
