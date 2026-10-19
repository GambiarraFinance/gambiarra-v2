// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title IGambMasterChef
/// @notice Minimal interface for the legacy, ownership-renounced Gambiarra Finance
///         MasterChef at 0x77c1618248358f92Cb144269790103e67378A550 (BSC mainnet).
/// @dev This contract is immutable (owner() == address(0)) and permissionless.
///      IMPORTANT: it lists the same GAMB/WBNB LP token under *two* pool ids
///      (16 and 25, as of the audit in this repo's README) with very different
///      allocPoint weights. Callers MUST pass the pool id explicitly and never
///      assume a 1:1 mapping between LP token and pool id.
interface IGambMasterChef {
    struct PoolInfo {
        address lpToken;
        uint256 allocPoint;
        uint256 lastRewardBlock;
        uint256 accGambPerShare;
    }

    struct UserInfo {
        uint256 amount; // LP tokens staked by this address in this pool
        uint256 rewardDebt;
    }

    function poolInfo(uint256 pid)
        external
        view
        returns (address lpToken, uint256 allocPoint, uint256 lastRewardBlock, uint256 accGambPerShare);

    function userInfo(uint256 pid, address user) external view returns (uint256 amount, uint256 rewardDebt);

    function poolLength() external view returns (uint256);

    function totalAllocPoint() external view returns (uint256);

    function gambPerBlock() external view returns (uint256);

    function gamb() external view returns (address);

    /// @notice Deposit `amount` of the pool's LP token. Depositing 0 just harvests
    ///         pending GAMB to msg.sender (standard MasterChef pattern).
    function deposit(uint256 pid, uint256 amount) external;

    /// @notice Withdraw `amount` of staked LP (and harvest pending GAMB).
    function withdraw(uint256 pid, uint256 amount) external;

    /// @notice Forfeits pending rewards — only ever used as a last-resort rescue path.
    function emergencyWithdraw(uint256 pid) external;

    function pendingGamb(uint256 pid, address user) external view returns (uint256);
}
