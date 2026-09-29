// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PactsBase} from "./PactsBase.t.sol";
import {Season} from "../src/Season.sol";
import {Banners} from "../src/Banners.sol";

contract SeasonTest is PactsBase {
    uint256 internal gA;
    uint256 internal gB;
    uint256 internal gC;

    function setUp() public override {
        super.setUp();
        gA = found(alice, "Alpha");
        gB = found(bob, "Beta");
        gC = found(carol, "Gamma");
        join(dave, gA);
    }

    /// @dev Season 0: Alpha 3 tiles, Beta 2, Gamma 1; fees 1.5 + 1 + 0.5 = 3e18.
    function playSeasonZero() internal {
        buy(alice, 30);
        buy(bob, 20);
        buy(carol, 10);
        uint256 pid = proposeAttack(alice, 0, 0, 10);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        pid = proposeAttack(alice, 1, 0, 10);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        pid = proposeAttack(alice, 2, 0, 10);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        attackNow(bob, 3, 0, 10);
        attackNow(bob, 4, 0, 10);
        attackNow(carol, 5, 0, 10);
    }

    function endSeasonZero() internal {
        warpToEpoch(EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
    }

    // ---------------------------------------------------------------- fees

    function test_feesAreBookedToTheSeasonTheyArePaidIn() public {
        buy(alice, 10);
        assertEq(season.prizePool(0), 0.5e18);
        warpToEpoch(EPOCHS_PER_SEASON);
        buy(alice, 10);
        assertEq(season.prizePool(0), 0.5e18);
        assertEq(season.prizePool(1), 0.5e18);
        assertEq(token.balanceOf(address(season)), 1e18);
    }

    function test_onlyRealmRecordsFees() public {
        vm.prank(outsider);
        vm.expectRevert(Season.NotRealm.selector);
        season.recordFee(0, 1);
    }

    // --------------------------------------------------------------- close

    function test_closeRequiresEndedAndSettledSeason() public {
        playSeasonZero();
        vm.expectRevert(Season.SeasonNotEnded.selector);
        season.close(0);
        warpToEpoch(EPOCHS_PER_SEASON);
        vm.expectRevert(Season.SeasonNotRecorded.selector);
        season.close(0);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(0);
        vm.expectRevert(Season.SeasonAlreadyClosed.selector);
        season.close(0);
    }

    function test_closeAllocatesFiftyThirtyTwenty() public {
        playSeasonZero();
        endSeasonZero();
        season.close(0);
        Season.Result memory r = season.getResult(0);
        assertTrue(r.closed);
        assertEq(r.pool, 3e18);
        assertEq(r.guildIds[0], gA);
        assertEq(r.guildIds[1], gB);
        assertEq(r.guildIds[2], gC);
        assertEq(r.tiles[0], 3);
        assertEq(r.guildPrize[0], 1.5e18);
        assertEq(r.guildPrize[1], 0.9e18);
        assertEq(r.guildPrize[2], 0.6e18);
        assertEq(r.memberCount[0], 2);
        assertEq(r.memberCount[1], 1);
        assertEq(r.perMember[0], 0.75e18);
        assertEq(r.perMember[1], 0.9e18);
        assertEq(r.perMember[2], 0.6e18);
        assertEq(r.rollover, 0);
        assertEq(season.prizePool(1), 0);
    }

    function test_unfilledRanksRollOver() public {
        buy(alice, 20); // fee 1e18
        uint256 pid = proposeAttack(alice, 0, 0, 10);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        endSeasonZero();
        season.close(0);
        Season.Result memory r = season.getResult(0);
        assertEq(r.guildPrize[0], 0.5e18);
        assertEq(r.guildIds[1], 0);
        assertEq(r.rollover, 0.5e18);
        assertEq(season.prizePool(1), 0.5e18);
    }

    function test_guildWithNoMembersAtSeasonEndRollsOver() public {
        capture(carol, 5, 10); // fee 0.5e18
        vm.prank(carol);
        guilds.leave();
        endSeasonZero();
        season.close(0);
        Season.Result memory r = season.getResult(0);
        assertEq(r.guildIds[0], gC);
        assertEq(r.guildPrize[0], 0);
        assertEq(r.rollover, 0.5e18);
    }

    function test_dustFromEqualSplitRollsOver() public {
        // Alpha has 3 members; a 1e18 pool gives a 0.5e18 first prize that does not divide by 3.
        join(erin, gA);
        buy(alice, 20);
        uint256 pid = proposeAttack(alice, 0, 0, 10);
        voteYes(dave, pid);
        realm.declareAttack(pid);
        endSeasonZero();
        season.close(0);
        Season.Result memory r = season.getResult(0);
        uint256 perMember = uint256(0.5e18) / 3;
        assertEq(r.perMember[0], perMember);
        assertEq(r.guildPrize[0], perMember * 3);
        assertEq(r.rollover, 1e18 - perMember * 3);
    }

    // -------------------------------------------------------------- claims

    function test_membersClaimEqualSharesAndBanners() public {
        playSeasonZero();
        endSeasonZero();
        season.close(0);
        uint256 before = token.balanceOf(alice);
        vm.prank(alice);
        (uint256 amount, uint256 tokenId) = season.claim(0, gA);
        assertEq(amount, 0.75e18);
        assertEq(token.balanceOf(alice), before + 0.75e18);
        assertEq(banners.ownerOf(tokenId), alice);
        Banners.Banner memory b = banners.bannerOf(tokenId);
        assertEq(b.season, 0);
        assertEq(b.guildId, gA);
        assertEq(uint256(b.kind), uint256(Banners.BannerKind.Winner));
        assertEq(b.rank, 1);

        vm.prank(dave);
        (amount,) = season.claim(0, gA);
        assertEq(amount, 0.75e18);
        vm.prank(bob);
        (amount, tokenId) = season.claim(0, gB);
        assertEq(amount, 0.9e18);
        assertEq(banners.bannerOf(tokenId).rank, 2);
        vm.prank(carol);
        (amount, tokenId) = season.claim(0, gC);
        assertEq(amount, 0.6e18);
        assertEq(banners.bannerOf(tokenId).rank, 3);
        assertEq(token.balanceOf(address(season)), 0);
        assertEq(banners.totalSupply(), 4);
        assertEq(banners.balanceOf(alice), 1);
    }

    function test_claimTwiceReverts() public {
        playSeasonZero();
        endSeasonZero();
        season.close(0);
        vm.prank(alice);
        season.claim(0, gA);
        vm.prank(alice);
        vm.expectRevert(Season.AlreadyClaimed.selector);
        season.claim(0, gA);
    }

    function test_claimBeforeCloseReverts() public {
        playSeasonZero();
        endSeasonZero();
        vm.prank(alice);
        vm.expectRevert(Season.SeasonNotClosed.selector);
        season.claim(0, gA);
    }

    function test_nonWinnerAndNonMemberCannotClaim() public {
        playSeasonZero();
        endSeasonZero();
        season.close(0);
        vm.prank(alice);
        vm.expectRevert(Season.NotAWinner.selector);
        season.claim(0, 4);
        vm.prank(alice);
        vm.expectRevert(Season.NotAWinner.selector);
        season.claim(0, 0);
        vm.prank(outsider);
        vm.expectRevert(Season.NotMemberAtSeasonEnd.selector);
        season.claim(0, gA);
        // Bob is a member of Beta, not Alpha.
        vm.prank(bob);
        vm.expectRevert(Season.NotMemberAtSeasonEnd.selector);
        season.claim(0, gA);
    }

    function test_memberJoiningAfterSeasonEndEarnsNothing() public {
        playSeasonZero();
        endSeasonZero();
        join(erin, gA); // joins in season 1
        season.close(0);
        Season.Result memory r = season.getResult(0);
        assertEq(r.memberCount[0], 2);
        vm.prank(erin);
        vm.expectRevert(Season.NotMemberAtSeasonEnd.selector);
        season.claim(0, gA);
        vm.prank(alice);
        (uint256 amount,) = season.claim(0, gA);
        assertEq(amount, 0.75e18);
    }

    function test_memberJoiningInLastSecondOfSeasonCounts() public {
        playSeasonZero();
        vm.warp(START + SEASON - 1);
        join(erin, gA);
        endSeasonZero();
        season.close(0);
        assertEq(season.getResult(0).memberCount[0], 3);
        vm.prank(erin);
        (uint256 amount,) = season.claim(0, gA);
        assertEq(amount, 0.5e18);
    }

    function test_memberLeavingAfterSeasonEndStillClaims() public {
        playSeasonZero();
        endSeasonZero();
        vm.prank(dave);
        guilds.leave();
        season.close(0);
        vm.prank(dave);
        (uint256 amount,) = season.claim(0, gA);
        assertEq(amount, 0.75e18);
    }

    function test_memberLeavingBeforeSeasonEndGetsNothing() public {
        playSeasonZero();
        vm.warp(START + SEASON - 1);
        vm.prank(dave);
        guilds.leave();
        endSeasonZero();
        season.close(0);
        assertEq(season.getResult(0).memberCount[0], 1);
        assertEq(season.getResult(0).perMember[0], 1.5e18);
        vm.prank(dave);
        vm.expectRevert(Season.NotMemberAtSeasonEnd.selector);
        season.claim(0, gA);
    }

    function test_rolloverFundsNextSeasonPrizes() public {
        capture(carol, 5, 10); // only Gamma holds tiles: 0.25e18 to Gamma, 0.25e18 rolls over
        endSeasonZero();
        season.close(0);
        assertEq(season.prizePool(1), 0.25e18);
        // Season 1: Gamma still holds its tile; Alpha buys troops for 1e18 of fees.
        buy(alice, 20);
        warpToEpoch(2 * EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(1);
        Season.Result memory r = season.getResult(1);
        assertEq(r.pool, 1.25e18);
        assertEq(r.guildIds[0], gC);
        assertEq(r.guildPrize[0], 0.625e18);
    }

    function test_seasonsCloseInOrderSoRolloverIsNeverStranded() public {
        capture(carol, 5, 10); // only Gamma holds a tile: half of every pool rolls over
        buy(alice, 20); // 1e18 of fees in season 0 (plus 0.5e18 from the capture)
        warpToEpoch(2 * EPOCHS_PER_SEASON);
        realm.settlePending(2 * EPOCHS_PER_SEASON);
        vm.expectRevert(Season.PreviousSeasonNotClosed.selector);
        season.close(1);
        season.close(0);
        season.close(1);
        Season.Result memory r0 = season.getResult(0);
        Season.Result memory r1 = season.getResult(1);
        assertEq(r0.pool, 1.5e18);
        assertEq(r0.rollover, 0.75e18);
        assertEq(r1.pool, 0.75e18);
        assertEq(r1.rollover, 0.375e18);
        assertEq(season.prizePool(2), 0.375e18);
        assertEq(token.balanceOf(address(season)), r0.guildPrize[0] + r1.guildPrize[0] + season.prizePool(2));
        // Season 2 can be closed only after both, and season 3 waits for it in turn.
        warpToEpoch(3 * EPOCHS_PER_SEASON);
        realm.settlePending(EPOCHS_PER_SEASON);
        season.close(2);
        assertEq(season.getResult(2).pool, 0.375e18);
    }

    // ------------------------------------------------------- peace banners

    function test_peaceBannerForGuildWithoutBetrayal() public {
        endSeasonZero();
        uint256 tokenId = season.mintPeaceBanner(0, gB);
        assertEq(banners.ownerOf(tokenId), address(guilds));
        Banners.Banner memory b = banners.bannerOf(tokenId);
        assertEq(uint256(b.kind), uint256(Banners.BannerKind.Peace));
        assertEq(b.guildId, gB);
        assertEq(b.rank, 0);
        vm.expectRevert(Season.AlreadyClaimed.selector);
        season.mintPeaceBanner(0, gB);
    }

    function test_peaceBannerDeniedToBetrayerAndLateGuilds() public {
        vm.prank(erin);
        guilds.deposit(gA, 10e18);
        vm.prank(erin);
        guilds.deposit(gB, 10e18);
        capture(bob, 7, 10);
        uint256 pa = proposePact(alice, gB, 1e18, 10);
        voteYes(dave, pa);
        uint256 pb = proposePact(bob, gA, 1e18, 10);
        diplomacy.sign(pa, pb);
        buy(alice, 1);
        uint256 attack = proposeAttack(alice, 7, gB, 1);
        voteYes(dave, attack);
        declareAs(alice, attack);
        assertEq(diplomacy.betrayals(gA, 0), 1);

        vm.expectRevert(Season.SeasonNotEnded.selector);
        season.mintPeaceBanner(0, gB);
        endSeasonZero();
        uint256 late = found(erin, "Late");
        vm.expectRevert(Season.GuildNotEligible.selector);
        season.mintPeaceBanner(0, gA); // betrayed
        vm.expectRevert(Season.GuildNotEligible.selector);
        season.mintPeaceBanner(0, late); // founded after the season ended
        vm.expectRevert(Season.GuildNotEligible.selector);
        season.mintPeaceBanner(0, 99); // no such guild
        season.mintPeaceBanner(0, gB); // the victim is eligible
        warpToEpoch(2 * EPOCHS_PER_SEASON);
        season.mintPeaceBanner(1, gA); // a new season starts clean
    }

    // ------------------------------------------------------------- banners

    function test_onlySeasonMintsBanners() public {
        vm.prank(outsider);
        vm.expectRevert(Banners.NotMinter.selector);
        banners.mint(outsider, 0, 1, Banners.BannerKind.Winner, 1);
        assertEq(banners.minter(), address(season));
    }

    function test_bannerTransfersAndMetadata() public {
        playSeasonZero();
        endSeasonZero();
        season.close(0);
        vm.prank(bob);
        (, uint256 tokenId) = season.claim(0, gB);
        assertTrue(banners.supportsInterface(0x80ac58cd));
        assertEq(banners.name(), "Pact Banners");
        string memory uri = banners.tokenURI(tokenId);
        assertEq(
            uri,
            string.concat(
                "data:application/json;utf8,{\"name\":\"Pact Banner #1\",\"description\":\"Pacts season trophy.\",",
                "\"attributes\":[{\"trait_type\":\"Kind\",\"value\":\"Winner\"},{\"trait_type\":\"Season\",\"value\":0},",
                "{\"trait_type\":\"Guild\",\"value\":2},{\"trait_type\":\"Rank\",\"value\":2}]}"
            )
        );
        vm.prank(outsider);
        vm.expectRevert(Banners.NotAuthorized.selector);
        banners.transferFrom(bob, outsider, tokenId);
        vm.prank(bob);
        banners.approve(carol, tokenId);
        vm.prank(carol);
        banners.safeTransferFrom(bob, outsider, tokenId);
        assertEq(banners.ownerOf(tokenId), outsider);
        assertEq(banners.balanceOf(bob), 0);
        assertEq(banners.getApproved(tokenId), address(0));
        vm.expectRevert(Banners.NoSuchToken.selector);
        banners.ownerOf(99);
    }
}
