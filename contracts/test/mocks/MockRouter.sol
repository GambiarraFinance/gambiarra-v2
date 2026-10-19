// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPancakeRouter02} from "../../src/interfaces/IPancakeRouter02.sol";
import {MockERC20} from "./MockERC20.sol";

/// @notice Test double for the PancakeSwap V2 router, scoped to what
///         GambVault and GambLeverageZap call.
/// @dev Two knobs drive the scenarios:
///      - `rateWad`: how much of the output token you get per unit of the
///        input token (1e18 == 1:1). Lower it to simulate a bad price.
///      - `splitBps`: how the LP liquidity is split between the two tokens
///        when liquidity is removed (5000 == 50/50).
///      Liquidity minted by `addLiquidity` is sqrt(amountA * amountB), so a
///      balanced deposit of X tokens mints exactly X LP units.
contract MockRouter is IPancakeRouter02 {
    uint256 public rateWad = 1e18;
    uint256 public splitBps = 5_000;
    uint256 public constant BPS = 10_000;

    MockERC20 public immutable lpToken;

    constructor(MockERC20 lpToken_) {
        lpToken = lpToken_;
    }

    function setRateWad(uint256 rateWad_) external {
        rateWad = rateWad_;
    }

    function setSplitBps(uint256 splitBps_) external {
        splitBps = splitBps_;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 1; i < path.length; i++) {
            amounts[i] = (amounts[i - 1] * rateWad) / 1e18;
        }
    }

    function swapExactTokensForTokensSupportingFeeOnTransferTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 deadline
    ) external {
        require(deadline >= block.timestamp, "EXPIRED");
        require(amountIn > 0, "INSUFFICIENT_INPUT_AMOUNT");

        IERC20(path[0]).transferFrom(msg.sender, address(this), amountIn);
        uint256 amountOut = (amountIn * rateWad) / 1e18;
        require(amountOut >= amountOutMin, "INSUFFICIENT_OUTPUT_AMOUNT");
        IERC20(path[1]).transfer(to, amountOut);
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        require(deadline >= block.timestamp, "EXPIRED");

        amountA = amountADesired;
        amountB = amountBDesired;
        require(amountA >= amountAMin, "INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "INSUFFICIENT_B_AMOUNT");

        IERC20(tokenA).transferFrom(msg.sender, address(this), amountA);
        IERC20(tokenB).transferFrom(msg.sender, address(this), amountB);

        // Balanced deposit of X + X mints exactly X LP units.
        liquidity = Math.sqrt(amountA * amountB);
        lpToken.mint(to, liquidity);
    }

    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint256 liquidity,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB) {
        require(deadline >= block.timestamp, "EXPIRED");

        amountB = (liquidity * splitBps) / BPS;
        amountA = liquidity - amountB;
        require(amountA >= amountAMin, "INSUFFICIENT_A_AMOUNT");
        require(amountB >= amountBMin, "INSUFFICIENT_B_AMOUNT");

        lpToken.burn(msg.sender, liquidity);
        IERC20(tokenA).transfer(to, amountA);
        IERC20(tokenB).transfer(to, amountB);
    }
}
