// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title IGambVault
/// @notice Minimal surface of GambVault that the rest of the protocol needs.
/// @dev Kept as an interface (instead of importing the concrete ERC4626 vault)
///      so GambLendingPool and GambLeverageZap can be unit-tested against a
///      lightweight mock, while production still wires the real GambVault.
interface IGambVault is IERC20 {
    function deposit(uint256 assets, address receiver) external returns (uint256 shares);

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets);

    function convertToAssets(uint256 shares) external view returns (uint256);
}
