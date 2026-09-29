// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The Realm surface that Diplomacy and Season read. Realm creates both in its constructor,
///         so they learn its address as `msg.sender` and never call it during construction.
interface IRealm {
    function genesis() external view returns (uint256);
    function epochLength() external view returns (uint256);
    function seasonLength() external view returns (uint256);
    function epochsPerSeason() external view returns (uint256);
    function currentEpoch() external view returns (uint256);
    function currentSeason() external view returns (uint256);
    function seasonOfEpoch(uint256 epoch) external view returns (uint256);
    function seasonEnd(uint256 season) external view returns (uint256);
    function hasPendingAttack(uint256 attacker, uint256 defender) external view returns (bool);
    function standingsOf(uint256 season)
        external
        view
        returns (uint256[3] memory guildIds, uint256[3] memory tiles, bool recorded);
}
