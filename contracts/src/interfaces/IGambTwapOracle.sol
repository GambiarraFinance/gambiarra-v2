// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @title IGambTwapOracle
/// @notice Price surface consumed by GambLendingPool for collateral valuation.
interface IGambTwapOracle {
    /// @notice Fair value of `lpAmount` GAMB/WBNB LP tokens, denominated in WBNB.
    function fairValueOfLpInWbnb(uint256 lpAmount) external view returns (uint256 valueInWbnb);
}
