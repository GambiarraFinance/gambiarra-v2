// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Callback interface a PancakeSwap V2 flash-swap caller must implement.
interface IPancakeCallee {
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external;
}
