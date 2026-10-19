// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

interface IPancakePair {
    function token0() external view returns (address);
    function token1() external view returns (address);
    function getReserves() external view returns (uint112 reserve0, uint112 reserve1, uint32 blockTimestampLast);
    function totalSupply() external view returns (uint256);

    /// @notice UQ112x112 cumulative price accumulator for token0/token1.
    /// @dev Only advances when the pair is touched (trade, mint, burn or
    ///      `sync()`), which is why a dormant pool needs a poke.
    function price0CumulativeLast() external view returns (uint256);
    function price1CumulativeLast() external view returns (uint256);

    /// @notice Re-reads the balances into the reserves and advances the price
    ///         accumulator without trading.
    /// @dev This is what lets a TWAP window advance on a pair nobody trades:
    ///      it moves `blockTimestampLast` to now and adds `price * elapsed`
    ///      to the accumulator, with zero price impact. It DOES fold any
    ///      unsolicited token donation into the reserves, so it is only safe
    ///      to call on a pair with no stray balances.
    function sync() external;
}
