// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";

contract DeployTest is Test {
    function test_deployWiresTheGameAgainstTheToken() public {
        vm.warp(1_700_000_000);
        Deploy script = new Deploy();
        LaunchToken token = new LaunchToken();
        (Guilds guilds, Realm realm) = script.deploy(IERC20(address(token)), script.defaultConfig());

        assertEq(address(guilds.token()), address(token));
        assertEq(address(realm.token()), address(token));
        assertEq(address(realm.guilds()), address(guilds));
        assertEq(realm.epochLength(), 1 hours);
        assertEq(realm.seasonLength(), 7 days);
        assertEq(realm.epochsPerSeason(), 168);
        assertEq(realm.troopPrice(), 1e18);
        assertEq(realm.feeBps(), 500);
        assertEq(realm.genesis(), guilds.genesis());
        assertEq(address(realm.diplomacy().realm()), address(realm));
        assertEq(address(realm.season().realm()), address(realm));
        assertEq(address(realm.season().diplomacy()), address(realm.diplomacy()));
        assertEq(realm.season().banners().minter(), address(realm.season()));
        // The game starts with no tokens: every payout must come from what players pay in.
        assertEq(token.balanceOf(address(realm)), 0);
        assertEq(token.balanceOf(address(guilds)), 0);
        assertEq(token.balanceOf(address(this)), token.totalSupply());
    }
}
