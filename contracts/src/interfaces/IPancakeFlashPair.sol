// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPancakePair} from "./IPancakePair.sol";

/// @title IPancakeFlashPair
/// @notice A PancakeSwap V2 style pair that also supports the flash-swap
///         callback.
/// @dev Extends `IPancakePair` instead of redeclaring it: a flash pair IS a
///      pair, and one source of truth avoids two interfaces drifting apart.
///      The GAMB/WBNB LP (a PancakeSwap **V1** pair) and the WBNB/BUSD flash
///      pair (a PancakeSwap **V2** pair) both satisfy this interface — the ABI
///      is identical across generations.
interface IPancakeFlashPair is IPancakePair {
    /// @notice Flash-borrow amount0Out/amount1Out to `to`, invoking
    ///         `IPancakeCallee(to).pancakeCall(...)` when `data` is non-empty.
    ///         The pair enforces repayment (principal + 0.25% fee) by the end
    ///         of this same call, or the whole transaction reverts.
    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external;
}
