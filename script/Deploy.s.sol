// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {LaunchToken} from "../src/LaunchToken.sol";
import {Guilds} from "../src/Guilds.sol";
import {Realm} from "../src/Realm.sol";

/// @notice Local/dev deployment mirroring the launch.json wiring. The Sepolia launch itself is done by
///         ProjectFactory from launch.json; this script never reads the environment and takes its
///         configuration as constants or arguments so tests can call `deploy` directly.
contract Deploy is Script {
    struct Config {
        uint256 epochLength;
        uint256 seasonLength;
        uint256 troopPrice;
        uint256 feeBps;
    }

    uint256 public constant EPOCH_LENGTH = 1 hours;
    uint256 public constant SEASON_LENGTH = 7 days;
    uint256 public constant TROOP_PRICE = 1e18;
    uint256 public constant FEE_BPS = 500;

    function defaultConfig() public pure returns (Config memory) {
        return
            Config({epochLength: EPOCH_LENGTH, seasonLength: SEASON_LENGTH, troopPrice: TROOP_PRICE, feeBps: FEE_BPS});
    }

    /// @notice Deploy Guilds and Realm (which creates Diplomacy, Season and Banners) against `token`.
    function deploy(IERC20 token, Config memory cfg) public returns (Guilds guilds, Realm realm) {
        guilds = new Guilds(token, cfg.epochLength);
        realm = new Realm(token, guilds, cfg.epochLength, cfg.seasonLength, cfg.troopPrice, cfg.feeBps);
    }

    function run() external returns (LaunchToken token, Guilds guilds, Realm realm) {
        vm.startBroadcast();
        token = new LaunchToken();
        (guilds, realm) = deploy(IERC20(address(token)), defaultConfig());
        vm.stopBroadcast();
    }
}
