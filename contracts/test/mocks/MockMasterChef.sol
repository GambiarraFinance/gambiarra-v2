// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IGambMasterChef} from "../../src/interfaces/IGambMasterChef.sol";

/// @notice Test double for the legacy, ownership-renounced Gambiarra MasterChef.
/// @dev Only the surface GambVault actually uses is modelled: staking LP into
///      a pool id, harvesting pending GAMB, and the emergency rescue path.
///      Rewards are paid from the mock's own GAMB balance, so a test funds it
///      by minting GAMB to this contract.
contract MockMasterChef is IGambMasterChef {
    address public lpToken;
    address public gambToken;
    uint256 public allocPoint;
    uint256 public lastRewardBlock;
    uint256 public accGambPerShare;

    mapping(uint256 => mapping(address => uint256)) internal staked;
    mapping(uint256 => mapping(address => uint256)) internal pending;
    bool internal depositReverts;

    constructor(address lpToken_) {
        lpToken = lpToken_;
        lastRewardBlock = block.number;
    }

    // --- setters used by tests ---

    function setLpToken(address lpToken_) external {
        lpToken = lpToken_;
    }

    function setGambToken(address gamb_) external {
        gambToken = gamb_;
    }

    /// @notice Queue `amount` GAMB as pending reward for `user` in `pid`.
    function setPendingGamb(uint256 pid, address user, uint256 amount) external {
        pending[pid][user] = amount;
    }

    function setAccGambPerShare(uint256 value) external {
        accGambPerShare = value;
    }

    // --- IGambMasterChef ---

    function poolInfo(uint256) external view returns (address, uint256, uint256, uint256) {
        return (lpToken, allocPoint, lastRewardBlock, accGambPerShare);
    }

    function userInfo(uint256 pid, address user) external view returns (uint256 amount, uint256 rewardDebt) {
        return (staked[pid][user], 0);
    }

    function poolLength() external view returns (uint256) {
        return 30;
    }

    function totalAllocPoint() external view returns (uint256) {
        return 1;
    }

    function gambPerBlock() external view returns (uint256) {
        return 3e18;
    }

    function gamb() external view returns (address) {
        return gambToken;
    }

    /// @dev The legacy MasterChef is ownership-renounced; the mock mirrors it
    ///      so tests can assert the same immutable fact.
    function owner() external pure returns (address) {
        return address(0);
    }

    function pendingGamb(uint256 pid, address user) external view returns (uint256) {
        return pending[pid][user];
    }

    /// @dev `deposit(pid, 0)` is the MasterChef idiom for "just harvest".
    function deposit(uint256 pid, uint256 amount) external {
        if (depositReverts) revert("MasterChef is broken");
        if (amount > 0) {
            staked[pid][msg.sender] += amount;
            IERC20(lpToken).transferFrom(msg.sender, address(this), amount);
        }
        _payPending(pid, msg.sender);
    }

    function withdraw(uint256 pid, uint256 amount) external {
        staked[pid][msg.sender] -= amount; // reverts on underflow
        if (amount > 0) {
            IERC20(lpToken).transfer(msg.sender, amount);
        }
        _payPending(pid, msg.sender);
    }

    /// @dev Forfeits pending rewards — the rescue path.
    function emergencyWithdraw(uint256 pid) external {
        uint256 amount = staked[pid][msg.sender];
        staked[pid][msg.sender] = 0;
        if (amount > 0) {
            IERC20(lpToken).transfer(msg.sender, amount);
        }
    }

    /// @dev Simulates the MasterChef being the thing that is broken: every
    ///      deposit (including the harvest idiom) reverts.
    function setDepositReverts(bool reverts_) external {
        depositReverts = reverts_;
    }

    function _payPending(uint256 pid, address user) internal {
        uint256 reward = pending[pid][user];
        if (reward == 0) return;
        pending[pid][user] = 0;
        IERC20(gambToken).transfer(user, reward);
    }
}
