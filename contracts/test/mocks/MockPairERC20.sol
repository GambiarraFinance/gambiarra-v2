// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {MockERC20} from "./MockERC20.sol";

/// @notice An ERC20 that also answers the PancakeSwap pair surface
///         (`token0` / `token1` / `getReserves`), because a real LP token IS
///         the pair. Contracts that read the pair's reserves to build
///         `removeLiquidity` minimums (GambLeverageZap) need both in one
///         address, which `MockERC20` alone cannot provide.
/// @dev Extends `MockERC20` so it can be handed anywhere a `MockERC20` LP is
///      expected (e.g. `MockRouter`), while still satisfying `IPancakePair`.
contract MockPairERC20 is MockERC20 {
    address public token0Addr;
    address public token1Addr;
    uint112 public reserve0;
    uint112 public reserve1;

    constructor(string memory name_, string memory symbol_, address token0_, address token1_)
        MockERC20(name_, symbol_)
    {
        token0Addr = token0_;
        token1Addr = token1_;
    }

    function token0() external view returns (address) {
        return token0Addr;
    }

    function token1() external view returns (address) {
        return token1Addr;
    }

    function getReserves() external view returns (uint112, uint112, uint32) {
        return (reserve0, reserve1, uint32(block.timestamp));
    }

    /// @notice Sets the reserves the zap reads when it builds the
    ///         proportional GAMB/WBNB split for `removeLiquidity`.
    function setReserves(uint112 reserve0_, uint112 reserve1_) external {
        reserve0 = reserve0_;
        reserve1 = reserve1_;
    }
}
