// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGambVault} from "../../src/interfaces/IGambVault.sol";

/// @notice Lightweight stand-in for GambVault's ERC20 + ERC4626 surface.
///         Used by GambLendingPool tests so they don't need a live MasterChef.
contract MockVault is ERC20, IGambVault {
    IERC20 public immutable assetToken;

    constructor(IERC20 asset_) ERC20("Mock GambVault", "mGAMB") {
        assetToken = asset_;
    }

    function asset() external view returns (address) {
        return address(assetToken);
    }

    /// @dev 1 share == 1 asset unit, kept intentionally trivial for tests.
    function convertToAssets(uint256 shares) public pure returns (uint256) {
        return shares;
    }

    function deposit(uint256 assets, address receiver) external returns (uint256 shares) {
        assetToken.transferFrom(msg.sender, address(this), assets);
        shares = assets;
        _mint(receiver, shares);
    }

    function redeem(uint256 shares, address receiver, address owner) external returns (uint256 assets) {
        if (msg.sender != owner) _spendAllowance(owner, msg.sender, shares);
        _burn(owner, shares);
        assets = convertToAssets(shares);
        assetToken.transfer(receiver, assets);
    }

    /// @notice Test-only shortcut to hand shares to a borrower.
    function mintShares(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
