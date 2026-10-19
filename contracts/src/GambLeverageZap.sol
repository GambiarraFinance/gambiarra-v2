// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

import {IPancakeFlashPair} from "./interfaces/IPancakeFlashPair.sol";
import {IPancakeCallee} from "./interfaces/IPancakeCallee.sol";
import {IPancakeRouter02} from "./interfaces/IPancakeRouter02.sol";
import {IGambVault} from "./interfaces/IGambVault.sol";
import {GambLendingPool} from "./GambLendingPool.sol";

/// @title GambLeverageZap
/// @notice One-transaction open/close for a leveraged GAMB/WBNB auto-compounding
///         position. The flash swap here provides ONLY atomicity/UX — it is
///         never the source of leverage capacity itself. The persistent debt
///         always lives in `GambLendingPool`, funded by that pool's real WBNB
///         suppliers. This contract never custodies a user's position between
///         transactions: collateral and debt are always recorded directly
///         under the user's own address in GambLendingPool (see "operator"
///         delegation below), so this zap holds no user funds outside of a
///         single atomic call.
///
/// @dev Before calling either entry point, a user must have, once:
///      1. `wbnb.approve(zap, amount)` for the principal they're putting in
///         (open) — not needed for close.
///      2. `lendingPool.approveOperator(address(zap))` — lets this contract
///         act on the user's behalf for `borrow` / `withdrawCollateral` only
///         (never `repay`, which is permissionless for anyone anyway, and
///         never `supply`/`redeem`, which this contract never touches).
contract GambLeverageZap is IPancakeCallee, Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    enum Mode {
        OPEN,
        CLOSE
    }

    struct OpenParams {
        address user;
        uint256 principalWbnb;
        uint256 minLpOut;
        uint256 deadline;
    }

    struct CloseParams {
        address user;
        uint256 minWbnbOut;
        uint256 deadline;
    }

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant MAX_LEVERAGE_BPS = 30_000; // hard cap: 3x
    uint256 public constant MIN_SLIPPAGE_BPS = 50;
    uint256 public constant MAX_SLIPPAGE_BPS = 500;
    // PancakeSwap V2 swap fee is 0.25%: repaying a flash swap of `amountOut`
    // requires amountOut * 10000 / 9975, rounded up.
    uint256 private constant FLASH_FEE_NUM = 10_000;
    uint256 private constant FLASH_FEE_DEN = 9_975;

    IERC20 public immutable wbnb;
    IERC20 public immutable gamb;
    IERC20 public immutable lpToken;
    IPancakeRouter02 public immutable router;
    IGambVault public immutable vault;
    GambLendingPool public immutable lendingPool;

    /// @notice A deep, liquid WBNB pair (e.g. WBNB/BUSD) used purely as the
    ///         flash-loan source. Deliberately NOT the thin GAMB/WBNB pair —
    ///         flash-borrowing from the very pool whose price backs our own
    ///         collateral valuation would be a bad idea even though no swap
    ///         against it happens in this contract.
    IPancakeFlashPair public immutable flashPair;
    bool public immutable flashPairWbnbIsToken0;

    uint256 public swapSlippageBps = 150; // 1.5%
    bool public openingPaused;

    event OpenedPosition(address indexed user, uint256 principalWbnb, uint256 totalDeployed, uint256 lpMinted, uint256 vaultSharesMinted, uint256 debtWbnb);
    event ClosedPosition(address indexed user, uint256 lpRedeemed, uint256 gambFromLp, uint256 wbnbReturnedToUser);
    event SlippageUpdated(uint256 newSlippageBps);
    event OpeningPausedSet(bool paused);

    error OpeningIsPaused();
    error BadLeverage();
    error BadFlashCaller();
    error BadFlashSender();
    error SlippageExceeded();
    error NoPosition();

    constructor(
        IERC20 wbnb_,
        IERC20 gamb_,
        IERC20 lpToken_,
        IPancakeRouter02 router_,
        IGambVault vault_,
        GambLendingPool lendingPool_,
        IPancakeFlashPair flashPair_,
        address initialOwner
    ) Ownable(initialOwner) {
        wbnb = wbnb_;
        gamb = gamb_;
        lpToken = lpToken_;
        router = router_;
        vault = vault_;
        lendingPool = lendingPool_;
        flashPair = flashPair_;

        bool wbnbIsToken0 = flashPair_.token0() == address(wbnb_);
        require(wbnbIsToken0 || flashPair_.token1() == address(wbnb_), "flash pair has no WBNB");
        flashPairWbnbIsToken0 = wbnbIsToken0;
    }

    // ---------------------------------------------------------------------
    // User entry points
    // ---------------------------------------------------------------------

    function openLeveragedPosition(uint256 principalWbnb, uint256 leverageBps, uint256 minLpOut, uint256 deadline)
        external
        nonReentrant
    {
        if (openingPaused) revert OpeningIsPaused();
        if (leverageBps <= MAX_BPS || leverageBps > MAX_LEVERAGE_BPS) revert BadLeverage();

        wbnb.safeTransferFrom(msg.sender, address(this), principalWbnb);

        uint256 totalDeploy = (principalWbnb * leverageBps) / MAX_BPS;
        uint256 borrowViaFlash = totalDeploy - principalWbnb;

        bytes memory inner = abi.encode(OpenParams(msg.sender, principalWbnb, minLpOut, deadline));
        _initiateFlash(borrowViaFlash, abi.encode(Mode.OPEN, inner));
    }

    function closeLeveragedPosition(uint256 minWbnbOut, uint256 deadline) external nonReentrant {
        (,, uint256 shares) = lendingPool.borrowers(msg.sender);
        if (shares == 0) revert NoPosition();

        // Settle interest first, otherwise `currentDebt` is only accurate as
        // of the last interaction (possibly days ago) and the 0.1% buffer
        // below would not cover it, making close revert with ExceedsLtv.
        lendingPool.accrueInterest();
        uint256 debtSnapshot = lendingPool.currentDebt(msg.sender);
        // +0.1% buffer over the last accrual snapshot so we flash-borrow
        // enough to cover interest accrued in the few seconds since; any
        // excess is simply refunded to the user at the end, unused.
        uint256 borrowAmount = debtSnapshot + (debtSnapshot / 1000) + 1;

        bytes memory inner = abi.encode(CloseParams(msg.sender, minWbnbOut, deadline));
        _initiateFlash(borrowAmount, abi.encode(Mode.CLOSE, inner));
    }

    // ---------------------------------------------------------------------
    // Flash swap plumbing
    // ---------------------------------------------------------------------

    function _initiateFlash(uint256 wbnbAmount, bytes memory data) internal {
        (uint256 amount0Out, uint256 amount1Out) =
            flashPairWbnbIsToken0 ? (wbnbAmount, uint256(0)) : (uint256(0), wbnbAmount);
        flashPair.swap(amount0Out, amount1Out, address(this), data);
    }

    function _flashRepayAmount(uint256 borrowed) internal pure returns (uint256) {
        return (borrowed * FLASH_FEE_NUM) / FLASH_FEE_DEN + 1;
    }

    /// @notice PancakeSwap V2 flash-swap callback. Only the flash pair itself
    ///         may call this, and only for a swap this contract initiated.
    function pancakeCall(address sender, uint256 amount0, uint256 amount1, bytes calldata data) external override {
        if (msg.sender != address(flashPair)) revert BadFlashCaller();
        if (sender != address(this)) revert BadFlashSender();

        uint256 borrowed = amount0 > 0 ? amount0 : amount1;
        (Mode mode, bytes memory inner) = abi.decode(data, (Mode, bytes));

        if (mode == Mode.OPEN) {
            _handleOpen(borrowed, abi.decode(inner, (OpenParams)));
        } else {
            _handleClose(borrowed, abi.decode(inner, (CloseParams)));
        }
    }

    function _handleOpen(uint256 borrowedWbnb, OpenParams memory p) internal {
        uint256 totalWbnb = borrowedWbnb + p.principalWbnb;
        uint256 half = totalWbnb / 2;
        uint256 otherHalf = totalWbnb - half;

        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(gamb);

        uint256 gambMinOut = _applySlippage(_quoteOut(half, path));
        wbnb.forceApprove(address(router), half);
        uint256 gambBefore = gamb.balanceOf(address(this));
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(half, gambMinOut, path, address(this), p.deadline);
        uint256 gambReceived = gamb.balanceOf(address(this)) - gambBefore;

        gamb.forceApprove(address(router), gambReceived);
        wbnb.forceApprove(address(router), otherHalf);
        (,, uint256 liquidity) = router.addLiquidity(
            address(gamb),
            address(wbnb),
            gambReceived,
            otherHalf,
            _applySlippage(gambReceived),
            _applySlippage(otherHalf),
            address(this),
            p.deadline
        );
        if (liquidity < p.minLpOut) revert SlippageExceeded();

        lpToken.forceApprove(address(vault), liquidity);
        uint256 sharesMinted = vault.deposit(liquidity, address(this));

        IERC20(address(vault)).forceApprove(address(lendingPool), sharesMinted);
        lendingPool.depositCollateral(sharesMinted, p.user);

        uint256 repayAmount = _flashRepayAmount(borrowedWbnb);
        lendingPool.borrow(repayAmount, p.user, address(this));

        wbnb.safeTransfer(address(flashPair), repayAmount);

        emit OpenedPosition(p.user, p.principalWbnb, totalWbnb, liquidity, sharesMinted, repayAmount);
    }

    function _handleClose(uint256 borrowedWbnb, CloseParams memory p) internal {
        wbnb.forceApprove(address(lendingPool), borrowedWbnb);
        lendingPool.repay(borrowedWbnb, p.user);

        (,, uint256 shares) = lendingPool.borrowers(p.user);
        lendingPool.withdrawCollateral(shares, p.user, address(this));

        uint256 lpAmount = vault.redeem(shares, address(this), address(this));

        lpToken.forceApprove(address(router), lpAmount);
        (uint256 gambOut,) = router.removeLiquidity(address(gamb), address(wbnb), lpAmount, 0, 0, address(this), p.deadline);

        address[] memory path = new address[](2);
        path[0] = address(gamb);
        path[1] = address(wbnb);
        uint256 wbnbMinOutFromGamb = _applySlippage(_quoteOut(gambOut, path));
        gamb.forceApprove(address(router), gambOut);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(gambOut, wbnbMinOutFromGamb, path, address(this), p.deadline);

        uint256 currentWbnbBal = wbnb.balanceOf(address(this));
        uint256 repayRequired = _flashRepayAmount(borrowedWbnb);
        require(currentWbnbBal >= repayRequired, "insufficient to close");

        uint256 leftover = currentWbnbBal - repayRequired;
        if (leftover < p.minWbnbOut) revert SlippageExceeded();

        wbnb.safeTransfer(address(flashPair), repayRequired);
        if (leftover > 0) wbnb.safeTransfer(p.user, leftover);

        emit ClosedPosition(p.user, lpAmount, gambOut, leftover);
    }

    function _quoteOut(uint256 amountIn, address[] memory path) internal view returns (uint256) {
        uint256[] memory amounts = router.getAmountsOut(amountIn, path);
        return amounts[amounts.length - 1];
    }

    function _applySlippage(uint256 amount) internal view returns (uint256) {
        return (amount * (MAX_BPS - swapSlippageBps)) / MAX_BPS;
    }

    // ---------------------------------------------------------------------
    // Owner controls
    // ---------------------------------------------------------------------

    function setSwapSlippageBps(uint256 newSlippageBps) external onlyOwner {
        require(newSlippageBps >= MIN_SLIPPAGE_BPS && newSlippageBps <= MAX_SLIPPAGE_BPS, "out of range");
        swapSlippageBps = newSlippageBps;
        emit SlippageUpdated(newSlippageBps);
    }

    /// @notice Only blocks NEW leveraged positions; closing always works.
    function setOpeningPaused(bool paused_) external onlyOwner {
        openingPaused = paused_;
        emit OpeningPausedSet(paused_);
    }

    function rescueToken(address token, uint256 amount, address to) external onlyOwner {
        IERC20(token).safeTransfer(to, amount);
    }
}
