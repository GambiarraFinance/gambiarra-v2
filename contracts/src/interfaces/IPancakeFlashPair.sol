// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice PancakeSwap V2 pair surface needed for TWAP reads and flash swaps.
interface IPancakeFlashPair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);
    function totalSupply() external view returns (uint256);

    /// @notice Flash-borrow amount0Out/amount1Out to `to`, invoking
    ///         `IPancakeCallee(to).pancakeCall(...)` when `data` is non-empty.
    ///         The pair enforces repayment (principal + 0.25% fee) by the end
    ///         of this same call, or the whole transaction reverts.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
