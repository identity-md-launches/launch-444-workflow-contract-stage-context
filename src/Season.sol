// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./interfaces/IERC20.sol";
import {IRealm} from "./interfaces/IRealm.sol";
import {Guilds} from "./Guilds.sol";
import {Diplomacy} from "./Diplomacy.sol";
import {Banners} from "./Banners.sol";

/// @title Season: prize pool, standings and trophies
/// @notice Realm forwards the fee on every troop purchase here, tagged with the season it was paid in.
///         Once a season has ended and Realm has settled its last epoch, anyone can close it: the top
///         three guilds by tiles held (recorded by Realm at the season's final settlement) are awarded
///         50/30/20 of the pool, each share split equally among the members the guild had at season
///         end. Members claim their share and receive a Winner banner. Any guild that existed at season
///         end and broke no pact during the season can have a Peace banner minted to the Guilds
///         contract on its behalf. Shares that have no winner or no members roll into the next season;
///         seasons close in order so that the next season's pool is always still open.
///
///         Created by Realm in its constructor; creates Banners in its own constructor.
contract Season {
    struct Result {
        bool closed;
        uint256 pool;
        uint256[3] guildIds;
        uint256[3] tiles;
        uint256[3] guildPrize;
        uint256[3] memberCount;
        uint256[3] perMember;
        uint256 rollover;
    }

    uint256 public constant SHARE_FIRST = 50;
    uint256 public constant SHARE_SECOND = 30;
    uint256 public constant SHARE_THIRD = 20;

    IERC20 public immutable token;
    Guilds public immutable guilds;
    IRealm public immutable realm;
    Diplomacy public immutable diplomacy;
    Banners public immutable banners;

    /// @notice Fees collected for a season, plus whatever rolled over from the previous one.
    mapping(uint256 season => uint256) public prizePool;
    mapping(uint256 season => Result) internal _results;
    mapping(uint256 season => mapping(uint256 guildId => mapping(address member => bool))) public claimed;
    mapping(uint256 season => mapping(uint256 guildId => bool)) public peaceBannerMinted;

    event FeeRecorded(uint256 indexed season, uint256 amount, uint256 pool);
    event SeasonClosed(
        uint256 indexed season, uint256[3] guildIds, uint256[3] tiles, uint256[3] guildPrize, uint256 rollover
    );
    event PrizeClaimed(
        uint256 indexed season, uint256 indexed guildId, address indexed member, uint256 amount, uint256 tokenId
    );
    event PeaceBannerMinted(uint256 indexed season, uint256 indexed guildId, uint256 tokenId);

    error NotRealm();
    error SeasonNotEnded();
    error SeasonNotRecorded();
    error SeasonAlreadyClosed();
    error PreviousSeasonNotClosed();
    error SeasonNotClosed();
    error NotAWinner();
    error NotMemberAtSeasonEnd();
    error AlreadyClaimed();
    error GuildNotEligible();
    error TransferFailed();

    constructor(IERC20 token_, Guilds guilds_, Diplomacy diplomacy_) {
        token = token_;
        guilds = guilds_;
        diplomacy = diplomacy_;
        realm = IRealm(msg.sender);
        banners = new Banners();
    }

    /// @notice Realm has already transferred `amount` here; book it to `season`.
    function recordFee(uint256 season, uint256 amount) external {
        if (msg.sender != address(realm)) revert NotRealm();
        prizePool[season] += amount;
        emit FeeRecorded(season, amount, prizePool[season]);
    }

    /// @notice Close an ended season. Anyone may call once Realm has settled the season's last epoch.
    ///         Seasons close in order, so the rollover of each season lands in a pool that is still open.
    function close(uint256 season) external {
        if (realm.currentSeason() <= season) revert SeasonNotEnded();
        Result storage r = _results[season];
        if (r.closed) revert SeasonAlreadyClosed();
        if (season != 0 && !_results[season - 1].closed) revert PreviousSeasonNotClosed();
        (uint256[3] memory ids, uint256[3] memory tiles, bool recorded) = realm.standingsOf(season);
        if (!recorded) revert SeasonNotRecorded();

        uint256 pool = prizePool[season];
        uint256 endInclusive = realm.seasonEnd(season) - 1;
        uint256 allocated;
        uint256[3] memory shares = [SHARE_FIRST, SHARE_SECOND, SHARE_THIRD];
        r.closed = true;
        r.pool = pool;
        for (uint256 i; i < 3; ++i) {
            r.guildIds[i] = ids[i];
            r.tiles[i] = tiles[i];
            if (ids[i] == 0) continue;
            uint256 count = guilds.memberCountAt(ids[i], endInclusive);
            if (count == 0) continue;
            uint256 share = pool * shares[i] / 100;
            uint256 perMember = share / count;
            r.guildPrize[i] = perMember * count;
            r.memberCount[i] = count;
            r.perMember[i] = perMember;
            allocated += perMember * count;
        }
        uint256 rollover = pool - allocated;
        r.rollover = rollover;
        prizePool[season + 1] += rollover;
        emit SeasonClosed(season, ids, tiles, r.guildPrize, rollover);
    }

    /// @notice Claim the caller's share of `guildId`'s prize for `season` and receive a Winner banner.
    function claim(uint256 season, uint256 guildId) external returns (uint256 amount, uint256 tokenId) {
        Result storage r = _results[season];
        if (!r.closed) revert SeasonNotClosed();
        uint256 rank = 3;
        for (uint256 i; i < 3; ++i) {
            if (r.guildIds[i] == guildId && guildId != 0) rank = i;
        }
        if (rank == 3) revert NotAWinner();
        if (!guilds.wasMemberAt(guildId, msg.sender, realm.seasonEnd(season) - 1)) revert NotMemberAtSeasonEnd();
        if (claimed[season][guildId][msg.sender]) revert AlreadyClaimed();
        claimed[season][guildId][msg.sender] = true;
        amount = r.perMember[rank];
        tokenId = banners.mint(msg.sender, season, guildId, Banners.BannerKind.Winner, uint8(rank + 1));
        emit PrizeClaimed(season, guildId, msg.sender, amount, tokenId);
        if (amount != 0 && !token.transfer(msg.sender, amount)) revert TransferFailed();
    }

    /// @notice Mint the Peace banner for a guild that existed at the end of `season` and broke no pact
    ///         during it. The banner is held by the Guilds contract on the guild's behalf. Anyone may call.
    function mintPeaceBanner(uint256 season, uint256 guildId) external returns (uint256 tokenId) {
        if (realm.currentSeason() <= season) revert SeasonNotEnded();
        if (peaceBannerMinted[season][guildId]) revert AlreadyClaimed();
        uint64 founded = guilds.foundedAt(guildId);
        if (founded == 0 || founded >= realm.seasonEnd(season)) revert GuildNotEligible();
        if (diplomacy.betrayals(guildId, season) != 0) revert GuildNotEligible();
        peaceBannerMinted[season][guildId] = true;
        tokenId = banners.mint(address(guilds), season, guildId, Banners.BannerKind.Peace, 0);
        emit PeaceBannerMinted(season, guildId, tokenId);
    }

    function getResult(uint256 season) external view returns (Result memory) {
        return _results[season];
    }
}
