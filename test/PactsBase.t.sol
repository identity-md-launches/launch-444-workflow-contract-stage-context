// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";
import {Diplomacy} from "../src/Diplomacy.sol";
import {Season} from "../src/Season.sol";
import {Banners} from "../src/Banners.sol";

/// @dev Shared fixture: a fresh game per test, no environment reads, deterministic timestamps.
abstract contract PactsBase is Test {
    uint256 internal constant EPOCH = 1 hours;
    uint256 internal constant SEASON = 7 days;
    uint256 internal constant EPOCHS_PER_SEASON = SEASON / EPOCH;
    uint256 internal constant PRICE = 1e18;
    uint256 internal constant FEE_BPS = 500; // 5%
    uint256 internal constant START = 1_700_000_000;
    uint256 internal constant FUNDS = 1_000_000e18;

    LaunchToken internal token;
    Guilds internal guilds;
    Realm internal realm;
    Diplomacy internal diplomacy;
    Season internal season;
    Banners internal banners;

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal dave = makeAddr("dave");
    address internal erin = makeAddr("erin");
    address internal frank = makeAddr("frank");
    address internal outsider = makeAddr("outsider");

    function setUp() public virtual {
        vm.warp(START);
        token = new LaunchToken();
        guilds = new Guilds(IERC20(address(token)), EPOCH);
        realm = new Realm(IERC20(address(token)), guilds, EPOCH, SEASON, PRICE, FEE_BPS);
        diplomacy = realm.diplomacy();
        season = realm.season();
        banners = season.banners();

        address[7] memory players = [alice, bob, carol, dave, erin, frank, outsider];
        for (uint256 i; i < players.length; ++i) {
            token.transfer(players[i], FUNDS);
            vm.prank(players[i]);
            token.approve(address(realm), type(uint256).max);
            vm.prank(players[i]);
            token.approve(address(guilds), type(uint256).max);
        }
    }

    // ------------------------------------------------------------- helpers

    function found(address who, string memory name) internal returns (uint256 id) {
        vm.prank(who);
        id = guilds.found(name);
    }

    function join(address who, uint256 guildId) internal {
        vm.prank(who);
        guilds.join(guildId);
    }

    function buy(address who, uint256 troops) internal {
        vm.prank(who);
        realm.buyTroops(troops);
    }

    function proposeAttack(address who, uint256 tile, uint256 holder, uint256 troops) internal returns (uint256 id) {
        vm.prank(who);
        id = guilds.propose(Guilds.Kind.Attack, address(realm), 0, tile, holder, troops);
    }

    function proposePact(address who, uint256 other, uint256 bond, uint256 epochs) internal returns (uint256 id) {
        vm.prank(who);
        id = guilds.propose(Guilds.Kind.Pact, address(diplomacy), bond, other, epochs, 0);
    }

    function voteYes(address who, uint256 proposalId) internal {
        vm.prank(who);
        guilds.vote(proposalId, true);
    }

    function warpToEpoch(uint256 epoch) internal {
        vm.warp(START + epoch * EPOCH);
    }

    function nextEpoch() internal {
        warpToEpoch(realm.currentEpoch() + 1);
    }

    /// @dev Attack with a single-member guild: propose (auto-approved) and declare in the same call.
    function attackNow(address who, uint256 tile, uint256 holder, uint256 troops) internal returns (uint256 pid) {
        pid = proposeAttack(who, tile, holder, troops);
        realm.declareAttack(pid);
    }

    /// @dev Declare an approved attack as `who` (a member must declare an attack that breaks a pact).
    function declareAs(address who, uint256 pid) internal returns (uint256 epoch) {
        vm.prank(who);
        epoch = realm.declareAttack(pid);
    }

    /// @dev Betray with a single-member guild: propose and declare as the member.
    function betrayNow(address who, uint256 tile, uint256 holder, uint256 troops) internal returns (uint256 pid) {
        pid = proposeAttack(who, tile, holder, troops);
        declareAs(who, pid);
    }

    /// @dev Give a single-member guild `troops` on `tile` by attacking an empty tile and settling.
    function capture(address who, uint256 tile, uint256 troops) internal {
        buy(who, troops);
        attackNow(who, tile, 0, troops);
        nextEpoch();
        realm.settle();
    }

    function tileHolder(uint256 tile) internal view returns (uint256 holder) {
        (holder,) = realm.tile(tile);
    }

    function tileGarrison(uint256 tile) internal view returns (uint256 garrison) {
        (, garrison) = realm.tile(tile);
    }
}
