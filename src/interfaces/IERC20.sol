// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice The ERC-20 surface the game uses. The launch token returns true and reverts on failure.
interface IERC20 {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
