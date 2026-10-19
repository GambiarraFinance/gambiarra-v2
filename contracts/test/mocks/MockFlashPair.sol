// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPancakeFlashPair} from "../../src/interfaces/IPancakeFlashPair.sol";
import {IPancakeCallee} from "../../src/interfaces/IPancakeCallee.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Minimal mock of a PancakeSwap V2 pair, just enough surface for
///         GambTwapOracle's unit tests: controllable reserves, totalSupply,
///         and a manually-advanceable cumulative price accumulator (so tests
///         can simulate time passing without needing a real fork).
/// @dev Once `setFlashToken` is called, `swap` also becomes a working
///      flash-swap (lend, callback, demand principal + 0.25% fee), so
///      GambLeverageZap can be unit-tested without a fork. Until then `swap`
///      keeps its original "this is not a real pair" behaviour.
contract MockFlashPair is IPancakeFlashPair {
    address public token0Addr;
    address public token1Addr;
    uint112 public reserve0;
    uint112 public reserve1;
    uint32 public blockTimestampLast;
    uint256 public price0CumulativeLast;
    uint256 public price1CumulativeLast;
    uint256 public totalSupplyAmount;
    /// @notice Optional token this mock lends out as a flash swap.
    address public flashToken;

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

    function swap(uint256 amount0Out, uint256 amount1Out, address to, bytes calldata data) external {
        if (flashToken == address(0)) revert("not implemented in mock");

        uint256 borrowed = amount0Out > 0 ? amount0Out : amount1Out;
        uint256 balanceBefore = MockERC20(flashToken).balanceOf(address(this));
        MockERC20(flashToken).mint(to, borrowed);

        IPancakeCallee(to).pancakeCall(msg.sender, amount0Out, amount1Out, data);

        // Same rule as the real PancakeSwap V2 pair: principal + 0.25% fee,
        // rounded up, paid back within the same call or the whole thing reverts.
        uint256 repayRequired = (borrowed * 10_000) / 9_975 + 1;
        require(MockERC20(flashToken).balanceOf(address(this)) - balanceBefore >= repayRequired, "flash not repaid");
    }

    /// @notice Enables the flash-swap behaviour for `token` (the token lent out).
    function setFlashToken(address token) external {
        flashToken = token;
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
