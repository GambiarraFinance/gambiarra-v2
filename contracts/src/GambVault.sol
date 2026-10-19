// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IGambMasterChef} from "./interfaces/IGambMasterChef.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";

/// @title GambVault
/// @notice Permissionless auto-compounding ERC4626 vault for the GAMB/WBNB
///         Cake-LP pair, staked against the legacy, ownership-renounced
///         Gambiarra Finance MasterChef. We cannot change anything about the
///         MasterChef (its owner is address(0)) — this vault is a satellite
///         contract built *on top of* it, not a modification of it.
///
/// @dev Known upstream facts this contract is written around (see repo README
///      for the full on-chain audit trail):
///      - MasterChef.owner() == address(0): fully immutable, no admin calls possible.
///      - The GAMB/WBNB LP token is listed under TWO pool ids (16 and 25) with
///        different allocPoint weights. `PID` below is fixed at construction
///        and can never be silently changed by this vault's owner.
///      - GAMB's own mint authority is the MasterChef itself; this vault never
///        mints GAMB, it only harvests and recompounds what the MasterChef pays out.
///      - As of the audit, real TVL in the target pool was tiny (~9 LP tokens),
///        so this vault uses OZ's ERC4626 decimals-offset virtual-shares guard
///        against first-depositor share-price inflation attacks.
contract GambVault is ERC4626, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    // ---------------------------------------------------------------------
    // Immutable wiring (set once at deploy, never changeable afterwards)
    // ---------------------------------------------------------------------

    IGambMasterChef public immutable masterChef;
    uint256 public immutable pid;
    IERC20 public immutable gamb;
    IERC20 public immutable wbnb;
    IPancakeRouter02 public immutable router;

    // ---------------------------------------------------------------------
    // Governance-adjustable parameters (hard-capped, timelock recommended
    // for the owner key in production — see README "Trust assumptions")
    // ---------------------------------------------------------------------

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant MAX_FEE_BPS = 1_000; // hard cap: fee can never exceed 10%
    uint256 public constant MAX_CALLER_INCENTIVE_BPS = 100; // hard cap: 1%
    uint256 public constant MIN_SLIPPAGE_BPS = 50; // floor: never allow < 0.5% slippage tolerance
    uint256 public constant MAX_SLIPPAGE_BPS = 500; // ceiling: never allow > 5% slippage tolerance

    uint256 public performanceFeeBps = 500; // 5% of harvested GAMB to feeRecipient
    uint256 public callerIncentiveBps = 50; // 0.5% of harvested GAMB to whoever calls harvest()
    uint256 public swapSlippageBps = 150; // 1.5% min-out tolerance on the compound swap/LP add
    address public feeRecipient;

    bool public depositsPaused;
    bool public emergencyExited; // true after emergencyExitMasterChef(), blocks harvest/compound

    // ---------------------------------------------------------------------
    // Events
    // ---------------------------------------------------------------------

    event Harvested(
        address indexed caller, uint256 gambHarvested, uint256 feeAmount, uint256 callerReward, uint256 lpCompounded
    );
    event FeeRecipientUpdated(address indexed newRecipient);
    event PerformanceFeeUpdated(uint256 newFeeBps);
    event CallerIncentiveUpdated(uint256 newIncentiveBps);
    event SlippageUpdated(uint256 newSlippageBps);
    event DepositsPausedSet(bool paused);
    event EmergencyExit(uint256 lpRecovered);
    event RescuedToken(address indexed token, uint256 amount, address indexed to);

    // ---------------------------------------------------------------------
    // Errors
    // ---------------------------------------------------------------------

    error FeeTooHigh();
    error IncentiveTooHigh();
    error SlippageOutOfRange();
    error CannotRescueVaultAsset();
    error ZeroAddress();
    error AlreadyExited();
    error SlippageExceeded();
    error DeadlineExpired();

    constructor(
        IERC20 lpAsset,
        IGambMasterChef masterChef_,
        uint256 pid_,
        IERC20 gamb_,
        IERC20 wbnb_,
        IPancakeRouter02 router_,
        address initialOwner,
        address initialFeeRecipient
    ) ERC20("Gambiarra Auto-Compounding GAMB/WBNB", "agGAMB-WBNB") ERC4626(lpAsset) Ownable(initialOwner) {
        if (initialFeeRecipient == address(0)) revert ZeroAddress();

        // Sanity-check the pool id actually points at this LP token. This is
        // a one-time deploy-time check only — PID is immutable afterwards.
        (address lpToken,,,) = masterChef_.poolInfo(pid_);
        require(lpToken == address(lpAsset), "pid/asset mismatch");

        masterChef = masterChef_;
        pid = pid_;
        gamb = gamb_;
        wbnb = wbnb_;
        router = router_;
        feeRecipient = initialFeeRecipient;
    }

    // ---------------------------------------------------------------------
    // ERC4626 core overrides
    // ---------------------------------------------------------------------

    /// @dev Virtual shares/assets offset (OZ ERC4626 inflation-attack guard).
    ///      Non-zero on purpose: the target pool had ~9 LP tokens of real TVL
    ///      at audit time, so a first-depositor donation attack is cheap to
    ///      attempt without this.
    function _decimalsOffset() internal pure override returns (uint8) {
        return 6;
    }

    /// @notice Total LP tokens this vault controls: staked in MasterChef plus
    ///         any idle dust sitting in the vault between compound steps.
    function totalAssets() public view override returns (uint256) {
        (uint256 staked,) = masterChef.userInfo(pid, address(this));
        return staked + IERC20(asset()).balanceOf(address(this));
    }

    /// @dev Pull assets in as usual, then immediately stake 100% of the
    ///      vault's idle LP balance into MasterChef so nothing sits idle
    ///      (and un-compounding) between deposits.
    function _deposit(address caller, address receiver, uint256 assets, uint256 shares) internal override nonReentrant {
        super._deposit(caller, receiver, assets, shares);
        _stakeIdleBalance();
    }

    /// @dev Unstake exactly what's needed from MasterChef before handing it
    ///      out, so the base ERC4626 transfer always has the balance it expects.
    function _withdraw(address caller, address receiver, address owner_, uint256 assets, uint256 shares)
        internal
        override
        nonReentrant
    {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle < assets && !emergencyExited) {
            masterChef.withdraw(pid, assets - idle);
        }
        super._withdraw(caller, receiver, owner_, assets, shares);
    }

    /// @notice Deposits are pausable (owner can stop new inflows if something
    ///         upstream looks wrong); withdrawals are NEVER pausable — this
    ///         function has no `paused` check on purpose.
    function maxDeposit(address) public view override returns (uint256) {
        return depositsPaused || emergencyExited ? 0 : type(uint256).max;
    }

    function maxMint(address) public view override returns (uint256) {
        return depositsPaused || emergencyExited ? 0 : type(uint256).max;
    }

    function _stakeIdleBalance() internal {
        uint256 idle = IERC20(asset()).balanceOf(address(this));
        if (idle == 0) return;
        IERC20(asset()).forceApprove(address(masterChef), idle);
        masterChef.deposit(pid, idle);
    }

    // ---------------------------------------------------------------------
    // Harvest / auto-compound — permissionless, callable by any keeper/agent
    // ---------------------------------------------------------------------

    /// @notice Claims pending GAMB from MasterChef, takes the performance fee
    ///         and caller incentive, swaps the remainder into GAMB/WBNB LP,
    ///         and restakes it. Anyone (a bot, a cron job, another agent) can
    ///         call this — that's the point: no human needs to babysit it.
    /// @param minLpOut Minimum LP tokens the caller accepts from the compound
    ///        leg. Reverts if fewer are minted.
    /// @param deadline Unix timestamp past which the swap/compound must not
    ///        execute. A caller-supplied deadline — instead of `block.timestamp`
    ///        — is what actually bounds how long a pending transaction may sit
    ///        in the mempool before landing at a stale price: a proposer cannot
    ///        defer it past this point.
    function harvest(uint256 minLpOut, uint256 deadline) external nonReentrant returns (uint256 lpCompounded) {
        if (emergencyExited) revert AlreadyExited();
        if (deadline < block.timestamp) revert DeadlineExpired();

        // deposit(pid, 0) is the standard MasterChef idiom for "just harvest".
        masterChef.deposit(pid, 0);

        uint256 gambBalance = gamb.balanceOf(address(this));
        if (gambBalance == 0) return 0;

        uint256 feeAmount = (gambBalance * performanceFeeBps) / MAX_BPS;
        uint256 callerReward = (gambBalance * callerIncentiveBps) / MAX_BPS;
        uint256 toCompound = gambBalance - feeAmount - callerReward;

        if (feeAmount > 0) gamb.safeTransfer(feeRecipient, feeAmount);
        if (callerReward > 0) gamb.safeTransfer(msg.sender, callerReward);

        // A compound leg needs at least 2 GAMB to split into two non-zero
        // legs. With less, the router reverts on a zero-amount swap and
        // harvest() stays bricked for good. The remainder just stays in the
        // vault and is picked up by the next harvest, which compounds the
        // vault's whole GAMB balance.
        if (toCompound < 2) {
            emit Harvested(msg.sender, gambBalance, feeAmount, callerReward, 0);
            return 0;
        }

        uint256 half = toCompound / 2;
        uint256 otherHalf = toCompound - half;

        address[] memory path = new address[](2);
        path[0] = address(gamb);
        path[1] = address(wbnb);

        uint256 wbnbMinOut = _applySlippage(_quoteOut(half, path));

        gamb.forceApprove(address(router), half);
        uint256 wbnbBefore = wbnb.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(half, wbnbMinOut, path, address(this), deadline);
        uint256 wbnbReceived = wbnb.balanceOf(address(this)) - wbnbBefore;

        // Re-check actual GAMB balance (defensive against fee-on-transfer
        // behaviour anywhere upstream) instead of trusting `otherHalf` math.
        uint256 gambForLp = gamb.balanceOf(address(this));
        if (gambForLp > otherHalf) gambForLp = otherHalf;

        gamb.forceApprove(address(router), gambForLp);
        wbnb.forceApprove(address(router), wbnbReceived);

        (,, uint256 liquidity) = router.addLiquidity(
            address(gamb),
            address(wbnb),
            gambForLp,
            wbnbReceived,
            _applySlippage(gambForLp),
            _applySlippage(wbnbReceived),
            address(this),
            deadline
        );

        if (liquidity < minLpOut) revert SlippageExceeded();

        _stakeIdleBalance();
        lpCompounded = liquidity;

        emit Harvested(msg.sender, gambBalance, feeAmount, callerReward, lpCompounded);
    }

    function _quoteOut(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return (amount * (MAX_BPS - swapSlippageBps)) / MAX_BPS;
    }

    /// @notice Read-only preview of pending GAMB rewards, for dashboards/agents.
    function pendingGamb() external view returns (uint256) {
        return masterChef.pendingGamb(pid, address(this));
    }

    // ---------------------------------------------------------------------
    // Owner controls — intentionally minimal. See README "Trust assumptions".
    // ---------------------------------------------------------------------

    function setFeeRecipient(address newRecipient) external onlyOwner {
        if (newRecipient == address(0)) revert ZeroAddress();
        feeRecipient = newRecipient;
        emit FeeRecipientUpdated(newRecipient);
    }

    function setPerformanceFeeBps(uint256 newFeeBps) external onlyOwner {
        if (newFeeBps > MAX_FEE_BPS) revert FeeTooHigh();
        performanceFeeBps = newFeeBps;
        emit PerformanceFeeUpdated(newFeeBps);
    }

    function setCallerIncentiveBps(uint256 newIncentiveBps) external onlyOwner {
        if (newIncentiveBps > MAX_CALLER_INCENTIVE_BPS) revert IncentiveTooHigh();
        callerIncentiveBps = newIncentiveBps;
        emit CallerIncentiveUpdated(newIncentiveBps);
    }

    function setSwapSlippageBps(uint256 newSlippageBps) external onlyOwner {
        if (newSlippageBps < MIN_SLIPPAGE_BPS || newSlippageBps > MAX_SLIPPAGE_BPS) revert SlippageOutOfRange();
        swapSlippageBps = newSlippageBps;
        emit SlippageUpdated(newSlippageBps);
    }

    function setDepositsPaused(bool paused_) external onlyOwner {
        depositsPaused = paused_;
        emit DepositsPausedSet(paused_);
    }

    /// @notice Rescue path if the upstream MasterChef, router, or LP pair ever
    ///         looks compromised/stuck: forfeits any unharvested GAMB rewards
    ///         and pulls all staked LP back into the vault's own balance.
    ///         After this, withdrawals keep working (assets still back shares
    ///         1:1 against the vault's idle LP balance); harvest() is disabled.
    function emergencyExitMasterChef() external onlyOwner {
        if (emergencyExited) revert AlreadyExited();
        emergencyExited = true;
        uint256 before = IERC20(asset()).balanceOf(address(this));
        masterChef.emergencyWithdraw(pid);
        uint256 recovered = IERC20(asset()).balanceOf(address(this)) - before;
        emit EmergencyExit(recovered);
    }

    /// @notice Sweep any token accidentally sent to this vault. Can never
    ///         touch the vault's own backing LP asset, the GAMB reward token
    ///         (pending rewards belong to depositors and anyone can collect
    ///         them via harvest()), or the vault's own share token.
    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        if (token == asset() || token == address(gamb) || token == address(this)) revert CannotRescueVaultAsset();
        if (to == address(0)) revert ZeroAddress();
        IERC20(token).safeTransfer(to, amount);
        emit RescuedToken(token, amount, to);
    }
}
