// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPancakeFlashPair} from "../../src/interfaces/IPancakeFlashPair.sol";

/// @notice Minimal mock of a PancakeSwap V2 pair, just enough surface for
///         GambTwapOracle's unit tests: controllable reserves, totalSupply,
///         and a manually-advanceable cumulative price accumulator (so tests
///         can simulate time passing without needing a real fork).
contract MockFlashPair is IPancakeFlashPair {
    address public token0Addr;
    address public token1Addr;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public totalSupplyAmount;

    constructor(address t0, address t1) {
        token0Addr = t0;
        token1Addr = t1;
        blockTimestampLast = uint32(block.timestamp);
    }

    function token0() external view returns (address) {
        return token0Addr;
    }

    function token1() external view returns (address) {
        return token1Addr;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, blockTimestampLast);
    }

    function totalSupply() external view returns (uint256) {
        return totalSupplyAmount;
    }

    function swap(uint256, uint256, address, bytes calldata) external pure {
        revert("not implemented in mock");
    }

    function setReserves(uint112 r0, uint112 r1) external {
        reserve0 = r0;
        reserve1 = r1;
    }

    function setTotalSupply(uint256 amount) external {
        totalSupplyAmount = amount;
    }

    /// @dev Simulates `timeElapsed` seconds passing at a constant spot price
    ///      of reserve1/reserve0 (standard Uniswap V2 accumulator math), so
    ///      GambTwapOracle.update() can be exercised deterministically.
    function advance(uint32 timeElapsed) external {
        uint256 Q112 = 2 ** 112;
        price0CumulativeLast += (uint256(reserve1) * Q112 / reserve0) * timeElapsed;
        price1CumulativeLast += (uint256(reserve0) * Q112 / reserve1) * timeElapsed;
        blockTimestampLast += timeElapsed;
    }

    /// @dev Mirrors the real pair's `sync()`: advances the accumulator by the
    ///      current price over the elapsed time and stamps the pair's
    ///      timestamp with now — no trade, no price impact.
    function sync() external {
        uint256 Q112 = 2 ** 112;
        uint32 blockTimestamp = uint32(block.timestamp);
        uint32 timeElapsed = blockTimestamp - blockTimestampLast;
        if (timeElapsed > 0 && reserve0 != 0 && reserve1 != 0) {
            price0CumulativeLast += (uint256(reserve1) * Q112 / reserve0) * timeElapsed;
            price1CumulativeLast += (uint256(reserve0) * Q112 / reserve1) * timeElapsed;
        }
        blockTimestampLast = blockTimestamp;
    }
}
