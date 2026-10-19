// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IGambTwapOracle} from "../../src/interfaces/IGambTwapOracle.sol";

/// @notice Settable-price oracle for GambLendingPool tests.
contract MockOracle is IGambTwapOracle {
    /// @notice LP price in WBNB, 1e18 fixed point.
    uint256 public priceWad = 1e18;

    function setPriceWad(uint256 newPriceWad) external {
        priceWad = newPriceWad;
    }

    function fairValueOfLpInWbnb(uint256 lpAmount) external view returns (uint256) {
        return (lpAmount * priceWad) / 1e18;
    }
}
