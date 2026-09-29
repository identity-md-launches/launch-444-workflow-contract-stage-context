// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Guilds} from "../src/Guilds.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";

/// @dev Executable examples of the permissionless rules and rounding risks documented in README.
contract RuleConsequencesTest is PactsBase {
    function test_openMembershipLetsFreshWalletMajoritySpendTreasury() public {
        uint256 g = found(alice, "Alpha");
        join(bob, g);
        join(carol, g);
        vm.prank(alice);
        guilds.deposit(g, 1000e18);
        address[4] memory newcomers = [address(101), address(102), address(103), address(104)];
        for (uint256 i; i < newcomers.length; ++i) {
            join(newcomers[i], g);
        }
        vm.prank(newcomers[0]);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, address(105), 1000e18, 0, 0, 0);
        for (uint256 i = 1; i < newcomers.length; ++i) {
            voteYes(newcomers[i], pid);
        }
        vm.prank(alice);
        guilds.vote(pid, false);
        vm.prank(bob);
        guilds.vote(pid, false);
        vm.prank(carol);
        guilds.vote(pid, false);
        guilds.execute(pid);
        assertEq(token.balanceOf(address(105)), 1000e18);
        assertEq(guilds.treasuryOf(g), 0);
    }

    function test_abandonedGuildTreasuryCanBeClaimedByNextJoiner() public {
        uint256 g = found(alice, "Alpha");
        vm.startPrank(alice);
        guilds.deposit(g, 1000e18);
        guilds.leave();
        vm.stopPrank();
        assertEq(guilds.memberCountOf(g), 0);
        join(outsider, g);
        vm.prank(outsider);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, outsider, 1000e18, 0, 0, 0);
        guilds.execute(pid);
        assertEq(token.balanceOf(outsider), FUNDS + 1000e18);
        assertEq(guilds.treasuryOf(g), 0);
    }

    function test_seasonEndSnapshotPaysFinalSecondJoiners() public {
        uint256 g = found(alice, "Alpha");
        capture(alice, 0, 1000);
        vm.warp(START + SEASON - 1);
        for (uint160 i = 101; i < 110; ++i) {
            join(address(i), g);
        }
        vm.warp(START + SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        assertEq(season.getResult(0).memberCount[0], 10);
        vm.prank(alice);
        (uint256 founderPrize,) = season.claim(0, g);
        assertEq(founderPrize, 2.5e18);
        uint256 newcomerPrize;
        for (uint160 i = 101; i < 110; ++i) {
            vm.prank(address(i));
            (uint256 amount, uint256 banner) = season.claim(0, g);
            newcomerPrize += amount;
            assertEq(banners.ownerOf(banner), address(i));
        }
        assertEq(newcomerPrize, 22.5e18);
        // Membership at the boundary itself is too late and cannot dilute the frozen shares.
        join(outsider, g);
        vm.prank(outsider);
        vm.expectRevert(Season.NotMemberAtSeasonEnd.selector);
        season.claim(0, g);
        assertEq(season.getResult(0).memberCount[0], 10);
        assertEq(founderPrize + newcomerPrize, season.getResult(0).guildPrize[0]);
    }

    function test_expulsionResetsVotingEligibilityButDoesNotBanRejoining() public {
        uint256 g = found(alice, "Alpha");
        join(bob, g);
        join(carol, g);
        uint256 oldAttack = proposeAttack(alice, 1, 0, 1);
        vm.prank(alice);
        uint256 expel = guilds.propose(Guilds.Kind.Expel, carol, 0, 0, 0, 0);
        voteYes(bob, expel);
        guilds.execute(expel);
        assertFalse(guilds.isMember(g, carol));
        join(carol, g);
        assertTrue(guilds.isMember(g, carol));
        vm.prank(carol);
        vm.expectRevert(Guilds.NotEligibleVoter.selector);
        guilds.vote(oldAttack, true);
        buy(alice, 100);
        uint256 attack = proposeAttack(alice, 0, 0, 100);
        voteYes(bob, attack);
        realm.declareAttack(attack);
        vm.warp(START + SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        vm.prank(carol);
        (uint256 amount,) = season.claim(0, g);
        assertEq(amount, uint256(2.5e18) / 3);
    }

    function test_zeroMinimumAcceptsCheapBetrayalBond() public {
        uint256 gA = found(alice, "Alpha");
        uint256 gB = found(bob, "Beta");
        vm.prank(alice);
        guilds.deposit(gA, 1000e18);
        vm.prank(bob);
        guilds.deposit(gB, 1);
        uint256 a = proposePact(alice, gB, 1000e18, 10);
        uint256 b = proposePact(bob, gA, 1, 10);
        vm.prank(outsider);
        uint256 pact = diplomacy.sign(a, b);
        assertEq(diplomacy.getPact(pact).bondA, 1000e18);
        assertEq(diplomacy.getPact(pact).bondB, 1);
        assertEq(guilds.treasuryOf(gA), 0);
        capture(alice, 0, 1);
        buy(bob, 1);
        betrayNow(bob, 0, gA, 1);
        assertEq(guilds.treasuryOf(gA), 1000e18 + 1);
        assertEq(uint256(diplomacy.getPact(pact).status), uint256(Diplomacy.Status.Broken));
    }

    function test_fractionalTroopLossesRoundDownToZero() public {
        uint256 gA = found(alice, "Alpha");
        uint256 gB = found(bob, "Beta");
        buy(alice, 1000);
        buy(bob, 2);
        attackNow(alice, 0, 0, 1);
        nextEpoch();
        realm.settle();
        attackNow(bob, 0, gA, 2);
        nextEpoch();
        realm.settle();
        assertEq(tileHolder(0), gB);
        assertEq(tileGarrison(0), 2);
        assertEq(realm.reserveOf(gA), 1000);
        attackNow(alice, 1, 0, 999);
        nextEpoch();
        realm.settle();
        buy(bob, 1);
        attackNow(bob, 1, gA, 1);
        nextEpoch();
        realm.settle();
        assertEq(tileGarrison(1), 999);
        assertEq(realm.reserveOf(gB), 1);
    }
}
