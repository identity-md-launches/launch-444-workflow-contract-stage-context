// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Guilds} from "../src/Guilds.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract GuildsTest is PactsBase {
    uint256 internal g1;

    function setUp() public override {
        super.setUp();
        g1 = found(alice, "Alpha");
    }

    // ---------------------------------------------------------- membership

    function test_foundAndJoin() public {
        assertEq(g1, 1);
        assertEq(guilds.guildOf(alice), 1);
        (string memory name, uint64 foundedAt, uint256 count, uint256 treasury) = guilds.getGuild(1);
        assertEq(name, "Alpha");
        assertEq(foundedAt, START);
        assertEq(count, 1);
        assertEq(treasury, 0);

        join(bob, 1);
        assertEq(guilds.memberCountOf(1), 2);
        assertTrue(guilds.isMember(1, bob));
        assertEq(guilds.memberSeq(1, bob), 2);
    }

    function test_cannotBeInTwoGuilds() public {
        vm.prank(alice);
        vm.expectRevert(Guilds.AlreadyInGuild.selector);
        guilds.found("Beta");
        found(bob, "Beta");
        vm.prank(bob);
        vm.expectRevert(Guilds.AlreadyInGuild.selector);
        guilds.join(1);
    }

    function test_joinUnknownGuildReverts() public {
        vm.prank(bob);
        vm.expectRevert(Guilds.NoSuchGuild.selector);
        guilds.join(7);
    }

    function test_invalidNameReverts() public {
        vm.prank(bob);
        vm.expectRevert(Guilds.InvalidName.selector);
        guilds.found("");
        vm.prank(bob);
        vm.expectRevert(Guilds.InvalidName.selector);
        guilds.found("this guild name is far too long to fit");
    }

    function test_leaveAndRejoinTracksStints() public {
        join(bob, 1);
        vm.warp(START + 100);
        vm.prank(bob);
        guilds.leave();
        assertEq(guilds.guildOf(bob), 0);
        assertEq(guilds.memberCountOf(1), 1);
        vm.warp(START + 200);
        join(bob, 1);
        assertEq(guilds.stintCount(1, bob), 2);
        assertTrue(guilds.wasMemberAt(1, bob, START + 50));
        assertFalse(guilds.wasMemberAt(1, bob, START + 150));
        assertTrue(guilds.wasMemberAt(1, bob, START + 200));
        assertFalse(guilds.wasMemberAt(1, bob, START - 1));
        assertEq(guilds.memberCountAt(1, START - 1), 0);
        assertEq(guilds.memberCountAt(1, START), 2);
        assertEq(guilds.memberCountAt(1, START + 100), 1);
        assertEq(guilds.memberCountAt(1, START + 199), 1);
        assertEq(guilds.memberCountAt(1, START + 200), 2);
        // Rejoining gives a new sequence number, so old proposals are not votable.
        assertEq(guilds.memberSeq(1, bob), 3);
    }

    function test_leaveWhenNotMemberReverts() public {
        vm.prank(bob);
        vm.expectRevert(Guilds.NotInGuild.selector);
        guilds.leave();
    }

    // ------------------------------------------------------------- voting

    function test_singleMemberProposalIsApprovedAtOnce() public {
        uint256 pid = proposeAttack(alice, 5, 0, 10);
        assertTrue(guilds.isApproved(pid));
        Guilds.Proposal memory p = guilds.getProposal(pid);
        assertEq(p.yesVotes, 1);
        assertEq(p.eligibleVoters, 1);
        assertEq(p.createdEpoch, 0);
    }

    function test_majorityIsStrict() public {
        join(bob, 1);
        join(carol, 1);
        join(dave, 1);
        uint256 pid = proposeAttack(alice, 5, 0, 10); // 1 of 4
        assertFalse(guilds.isApproved(pid));
        voteYes(bob, pid); // 2 of 4 is not a majority
        assertFalse(guilds.isApproved(pid));
        vm.prank(carol);
        guilds.vote(pid, false);
        assertFalse(guilds.isApproved(pid));
        voteYes(dave, pid); // 3 of 4
        assertTrue(guilds.isApproved(pid));
    }

    function test_memberJoiningAfterProposalCannotVote() public {
        join(bob, 1);
        uint256 pid = proposeAttack(alice, 5, 0, 10);
        join(carol, 1);
        vm.prank(carol);
        vm.expectRevert(Guilds.NotEligibleVoter.selector);
        guilds.vote(pid, true);
        // The denominator is fixed at creation: bob's vote is enough.
        voteYes(bob, pid);
        assertTrue(guilds.isApproved(pid));
    }

    function test_nonMemberAndDoubleVoteRevert() public {
        join(bob, 1);
        uint256 pid = proposeAttack(alice, 5, 0, 10);
        vm.prank(outsider);
        vm.expectRevert(Guilds.NotEligibleVoter.selector);
        guilds.vote(pid, true);
        vm.prank(alice);
        vm.expectRevert(Guilds.AlreadyVoted.selector);
        guilds.vote(pid, true);
        vm.prank(bob);
        guilds.vote(pid, false);
        vm.prank(bob);
        vm.expectRevert(Guilds.AlreadyVoted.selector);
        guilds.vote(pid, true);
    }

    function test_expelledMemberLosesVote() public {
        join(bob, 1);
        join(carol, 1);
        uint256 attack = proposeAttack(alice, 5, 0, 10);
        vm.prank(alice);
        uint256 expel = guilds.propose(Guilds.Kind.Expel, bob, 0, 0, 0, 0);
        voteYes(carol, expel);
        guilds.execute(expel);
        assertFalse(guilds.isMember(1, bob));
        assertEq(guilds.guildOf(bob), 0);
        vm.prank(bob);
        vm.expectRevert(Guilds.NotEligibleVoter.selector);
        guilds.vote(attack, true);
    }

    function test_expelRequiresActiveMember() public {
        join(bob, 1);
        vm.prank(alice);
        uint256 expel = guilds.propose(Guilds.Kind.Expel, carol, 0, 0, 0, 0);
        voteYes(bob, expel);
        vm.expectRevert(Guilds.NotMember.selector);
        guilds.execute(expel);
    }

    function test_proposalExpiresAfterNextEpoch() public {
        join(bob, 1);
        warpToEpoch(3);
        uint256 pid = proposeAttack(alice, 5, 0, 10);
        assertEq(guilds.getProposal(pid).createdEpoch, 3);
        warpToEpoch(4);
        assertFalse(guilds.isExpired(pid));
        vm.warp(START + 5 * EPOCH - 1);
        assertFalse(guilds.isExpired(pid));
        voteYes(bob, pid);
        warpToEpoch(5);
        assertTrue(guilds.isExpired(pid));
        vm.prank(address(realm));
        vm.expectRevert(Guilds.ProposalExpired.selector);
        guilds.consume(pid);
    }

    function test_voteOnExpiredProposalReverts() public {
        join(bob, 1);
        uint256 pid = proposeAttack(alice, 5, 0, 10);
        warpToEpoch(2);
        vm.prank(bob);
        vm.expectRevert(Guilds.ProposalExpired.selector);
        guilds.vote(pid, true);
    }

    function test_proposalValidation() public {
        vm.startPrank(alice);
        vm.expectRevert(Guilds.ZeroAddress.selector);
        guilds.propose(Guilds.Kind.Attack, address(0), 0, 1, 0, 1);
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Attack, address(realm), 1, 1, 0, 1); // attacks carry no amount
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Attack, address(realm), 0, 1, 0, 0); // zero troops
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Payout, bob, 0, 0, 0, 0); // zero amount
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.TreasuryTroops, address(realm), 0, 0, 0, 0);
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Pact, address(diplomacy), 0, 2, 3, 0); // zero bond
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Pact, address(diplomacy), 1, 1, 3, 0); // pact with itself
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Pact, address(diplomacy), 1, 9, 3, 0); // no such guild
        vm.expectRevert(Guilds.InvalidProposal.selector);
        guilds.propose(Guilds.Kind.Expel, bob, 5, 0, 0, 0); // expel carries no amount
        vm.stopPrank();
        vm.prank(outsider);
        vm.expectRevert(Guilds.NotInGuild.selector);
        guilds.propose(Guilds.Kind.Expel, bob, 0, 0, 0, 0);
        vm.expectRevert(Guilds.NoSuchProposal.selector);
        guilds.getProposal(0);
    }

    // ----------------------------------------------------------- treasury

    function test_depositAndPayoutNeedsMajority() public {
        join(bob, 1);
        vm.prank(carol);
        guilds.deposit(1, 100e18);
        assertEq(guilds.treasuryOf(1), 100e18);
        assertEq(token.balanceOf(address(guilds)), 100e18);

        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, dave, 60e18, 0, 0, 0);
        vm.expectRevert(Guilds.ProposalNotApproved.selector);
        guilds.execute(pid);
        voteYes(bob, pid);
        guilds.execute(pid);
        assertEq(token.balanceOf(dave), FUNDS + 60e18);
        assertEq(guilds.treasuryOf(1), 40e18);
        vm.expectRevert(Guilds.ProposalAlreadyExecuted.selector);
        guilds.execute(pid);
    }

    function test_payoutFailsWhenTreasuryTooSmall() public {
        vm.prank(carol);
        guilds.deposit(1, 10e18);
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, dave, 11e18, 0, 0, 0);
        vm.expectRevert(abi.encodeWithSelector(Guilds.InsufficientTreasury.selector, 10e18, 11e18));
        guilds.execute(pid);
    }

    function test_depositToUnknownGuildReverts() public {
        vm.prank(carol);
        vm.expectRevert(Guilds.NoSuchGuild.selector);
        guilds.deposit(3, 1);
    }

    function test_executeRejectsConsumerKinds() public {
        uint256 pid = proposeAttack(alice, 5, 0, 10);
        vm.expectRevert(Guilds.WrongKind.selector);
        guilds.execute(pid);
    }

    function test_consumeOnlyByNamedTarget() public {
        vm.prank(carol);
        guilds.deposit(1, 10e18);
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.TreasuryTroops, address(realm), 4e18, 0, 0, 0);
        vm.prank(outsider);
        vm.expectRevert(Guilds.NotTarget.selector);
        guilds.consume(pid);
        vm.prank(alice);
        vm.expectRevert(Guilds.NotTarget.selector);
        guilds.consume(pid);
        // The named target receives exactly the approved amount, once.
        vm.prank(address(realm));
        Guilds.Proposal memory p = guilds.consume(pid);
        assertEq(p.amount, 4e18);
        assertEq(token.balanceOf(address(realm)), 4e18);
        assertEq(guilds.treasuryOf(1), 6e18);
        vm.prank(address(realm));
        vm.expectRevert(Guilds.ProposalAlreadyExecuted.selector);
        guilds.consume(pid);
    }

    function test_consumeRejectsLocalKinds() public {
        vm.prank(alice);
        uint256 pid = guilds.propose(Guilds.Kind.Payout, bob, 1, 0, 0, 0);
        vm.prank(bob);
        vm.expectRevert(Guilds.WrongKind.selector);
        guilds.consume(pid);
    }

    function test_constructorRejectsBadArguments() public {
        vm.expectRevert(Guilds.InvalidEpochLength.selector);
        new Guilds(IERC20(address(token)), 0);
    }
}
