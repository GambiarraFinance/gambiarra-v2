// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Ownable2Step, Ownable} from "@openzeppelin/contracts/access/Ownable2Step.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

import {IGambTwapOracle} from "./interfaces/IGambTwapOracle.sol";
import {IGambVault} from "./interfaces/IGambVault.sol";

/// @title GambLendingPool
/// @notice Single-asset (WBNB) isolated lending pool. Suppliers deposit WBNB
///         to earn interest; borrowers post GambVault shares (agGAMB-WBNB) as
///         collateral and borrow WBNB against them. This is the actual source
///         of leverage for `GambLeverageZap` — the flash loan in that
///         contract only provides one-transaction UX, the persistent debt
///         position lives here.
///
/// @dev THIS IS THE RISKIEST CONTRACT IN THE REPO. Collateral is an illiquid
///      LP token for a project token with no independent price feed; all
///      valuation runs through `GambTwapOracle`, which can still be stale or
///      (over a long enough attack, across many blocks) manipulated. Defaults
///      are intentionally conservative (40% max LTV, 50% liquidation
///      threshold). Bad debt (bailed out by nobody — suppliers eat it) is
///      possible if collateral value collapses faster than liquidators react;
///      this is disclosed, not hidden, and must be re-verified by
///      `contract-auditor` before any non-trivial TVL touches this contract.
contract GambLendingPool is Ownable2Step, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint256 public constant MAX_BPS = 10_000;
    uint256 public constant WAD = 1e18;
    uint256 public constant SECONDS_PER_YEAR = 365 days;
    uint256 public constant MAX_LIQUIDATION_THRESHOLD_BPS = 8_000; // hard cap 80%
    uint256 public constant MAX_RESERVE_FACTOR_BPS = 2_000; // hard cap 20%
    uint256 public constant MAX_LIQUIDATION_BONUS_BPS = 1_500; // hard cap 15%
    /// @dev Maximum share of a position's debt that ONE liquidation may repay.
    uint256 public constant MAX_CLOSE_FACTOR_BPS = 5_000; // 50%
    /// @dev Positions at or below this debt are liquidated in a single call,
    ///      so the close factor can never leave dust bad debt behind.
    uint256 public constant DUST_DEBT = 1e12;
    uint256 public constant LTV_SAFETY_BUFFER_BPS = 500; // maxLtv must stay >=5% below liq. threshold
    /// @dev bps (1e4) -> wad-per-year (1e18): multiply by 1e14.
    uint256 private constant BPS_TO_WAD_PER_YEAR = 1e14;

    // Virtual shares/assets offset, same inflation-attack guard idea as
    // GambVault's ERC4626 `_decimalsOffset()`. Without this, the very first
    // supplier sets an arbitrary 1:1 share price, and an attacker can supply
    // a dust amount, then donate raw WBNB directly to this contract (a plain
    // `wbnb.transfer`, bypassing `supply()`) to inflate `_totalAssets()`
    // relative to `totalSupplyShares`. The next real depositor's shares then
    // round down to zero (they get nothing), and the attacker redeems their
    // dust share for the victim's deposit. Mixing in a large virtual share
    // count makes that donation economically unprofitable: the attacker's
    // own 1-wei stake is diluted by VIRTUAL_SHARES virtual shares nobody
    // owns, so the ratio barely moves no matter how much they donate.
    uint256 public constant VIRTUAL_SHARES = 1e6;
    uint256 public constant VIRTUAL_ASSETS = 1;

    IERC20 public immutable wbnb;
    IERC20 public immutable collateralToken; // GambVault shares (agGAMB-WBNB)
    IGambVault public immutable vault;
    IGambTwapOracle public immutable oracle;

    // --- supply side ---
    mapping(address => uint256) public supplyShares;
    uint256 public totalSupplyShares;
    uint256 public totalReserves;

    // --- borrow side ---
    struct BorrowerInfo {
        uint256 principal;
        uint256 indexSnapshot;
        uint256 collateralShares; // vault shares posted as collateral
    }

    mapping(address => BorrowerInfo) public borrowers;
    mapping(address => mapping(address => bool)) public isOperator; // owner => operator => approved
    uint256 public totalBorrows;
    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrualTimestamp;

    // --- risk params (owner-adjustable within hard caps) ---
    uint256 public maxLtvBps = 4_000; // 40%
    uint256 public liquidationThresholdBps = 5_000; // 50%
    uint256 public liquidationBonusBps = 1_000; // 10%
    uint256 public reserveFactorBps = 1_000; // 10%
    uint256 public baseRatePerSecond = uint256(0.02e18) / SECONDS_PER_YEAR; // 2%/yr
    uint256 public multiplierPerSecond = uint256(0.38e18) / SECONDS_PER_YEAR; // +38%/yr at 100% utilization

    bool public borrowingPaused;

    event Supplied(address indexed supplier, uint256 wbnbAmount, uint256 sharesMinted);
    event Redeemed(address indexed supplier, uint256 wbnbAmount, uint256 sharesBurned);
    event CollateralDeposited(address indexed onBehalfOf, address indexed payer, uint256 shares);
    event CollateralWithdrawn(address indexed onBehalfOf, address indexed to, uint256 shares);
    event Borrowed(address indexed onBehalfOf, address indexed to, uint256 amount);
    event Repaid(address indexed onBehalfOf, address indexed payer, uint256 amount);
    event Liquidated(address indexed borrower, address indexed liquidator, uint256 repaid, uint256 collateralSeized);
    event OperatorSet(address indexed owner_, address indexed operator, bool approved);
    event RiskParamsUpdated();
    event ReservesWithdrawn(uint256 amount, address indexed to);
    event BorrowingPausedSet(bool paused);

    /// @notice Emitted whenever interest is accrued onto the global borrow
    ///         index. Without it, suppliers/agents had no on-chain signal that
    ///         the debt grew — only a balance delta.
    event InterestAccrued(
        uint256 borrowIndex, uint256 totalBorrows, uint256 totalReserves, uint256 interestAccumulated
    );

    error NotAuthorized();
    error BorrowingIsPaused();
    error InsufficientLiquidity();
    error ExceedsLtv();
    error NotUndercollateralized();
    error RiskParamOutOfRange();
    error ZeroAddress();
    error OperatorCannotBorrowForOthers();
    error OperatorCannotWithdrawCollateral();
    error OperatorCannotActOnLiveDebt();
    error RateModelOutOfRange();

    constructor(IERC20 wbnb_, IGambVault vault_, IGambTwapOracle oracle_, address initialOwner) Ownable(initialOwner) {
        wbnb = wbnb_;
        vault = vault_;
        collateralToken = IERC20(address(vault_));
        oracle = oracle_;
        lastAccrualTimestamp = block.timestamp;
    }

    // ---------------------------------------------------------------------
    // Operator approvals (Aave-style "onBehalfOf" delegation, scoped to this
    // contract only — never a blanket token allowance).
    //
    // The delegation is deliberately NARROW, because an operator is a
    // contract and a contract can be compromised. What an operator may do:
    //   - borrow, but only into its own hands;
    //   - withdraw collateral, but only from a position with no debt left
    //     (i.e. closing it) and only into its own hands;
    //   - repay the borrower's debt (repay is permissionless anyway).
    // What it may NOT do: send the borrower's WBNB anywhere, or pull the
    // borrower's collateral out from under a live debt. Without those bounds,
    // one compromised operator would drain every borrower who ever approved
    // it. See `borrow()` and `withdrawCollateral()`.
    // ---------------------------------------------------------------------

    function approveOperator(address operator) external {
        isOperator[msg.sender][operator] = true;
        emit OperatorSet(msg.sender, operator, true);
    }

    function revokeOperator(address operator) external {
        isOperator[msg.sender][operator] = false;
        emit OperatorSet(msg.sender, operator, false);
    }

    function _checkAuthorized(address onBehalfOf) internal view {
        if (msg.sender != onBehalfOf && !isOperator[onBehalfOf][msg.sender]) revert NotAuthorized();
    }

    // ---------------------------------------------------------------------
    // Interest accrual (Compound-style global index)
    // ---------------------------------------------------------------------

    function accrueInterest() public {
        uint256 elapsed = block.timestamp - lastAccrualTimestamp;
        if (elapsed == 0) return;

        uint256 cash = wbnb.balanceOf(address(this));
        uint256 borrowsPrior = totalBorrows;
        uint256 rate = _ratePerSecond(cash, borrowsPrior);

        uint256 interestAccumulated = 0;
        if (borrowsPrior > 0 && rate > 0) {
            // The index moves first, and the aggregate debt is then scaled by
            // the SAME ratio — so `totalBorrows` keeps tracking the sum of the
            // index-based borrower debts instead of drifting away from it.
            //
            // Scaling by rate and elapsed time directly looked equivalent but
            // was not: `borrowsPrior * rate / 1e18` truncates by up to one
            // unit, and `elapsed` then multiplied that error — the aggregate
            // ended up BELOW the sum of the debts, and `totalBorrows -=
            // repaid` underflowed. repay() and liquidate() then reverted for
            // good, leaving the debt permanently unpayable. Caught by the
            // fork test against real interest accrual.
            uint256 indexDelta = Math.mulDiv(Math.mulDiv(borrowIndex, rate, WAD), elapsed, 1);
            uint256 newBorrowIndex = borrowIndex + indexDelta;

            // For a borrower whose index snapshot is the current index, this
            // is exactly their debt growth: p * indexDelta / borrowIndex.
            interestAccumulated = Math.mulDiv(borrowsPrior, indexDelta, borrowIndex);
            uint256 reservesDelta = Math.mulDiv(interestAccumulated, reserveFactorBps, MAX_BPS);
            totalBorrows = borrowsPrior + interestAccumulated;
            totalReserves += reservesDelta;
            borrowIndex = newBorrowIndex;
        }

        lastAccrualTimestamp = block.timestamp;

        emit InterestAccrued(borrowIndex, totalBorrows, totalReserves, interestAccumulated);
    }

    function _ratePerSecond(uint256 cash, uint256 borrows) internal view returns (uint256) {
        uint256 pool = cash + borrows;
        if (pool == 0) return baseRatePerSecond;
        uint256 utilizationWad = Math.mulDiv(borrows, WAD, pool);
        return baseRatePerSecond + Math.mulDiv(utilizationWad, multiplierPerSecond, WAD);
    }

    function _currentDebt(BorrowerInfo storage info) internal view returns (uint256) {
        if (info.principal == 0) return 0;
        return (info.principal * borrowIndex) / info.indexSnapshot;
    }

    /// @notice Current owed WBNB (principal + accrued interest) for `borrower`,
    ///         as of the last `accrueInterest()` call (view — does not accrue).
    function currentDebt(address borrower) external view returns (uint256) {
        BorrowerInfo storage info = borrowers[borrower];
        if (info.principal == 0) return 0;
        return (info.principal * borrowIndex) / info.indexSnapshot;
    }

    // ---------------------------------------------------------------------
    // Supply side
    // ---------------------------------------------------------------------

    function _totalAssets() internal view returns (uint256) {
        return wbnb.balanceOf(address(this)) + totalBorrows - totalReserves;
    }

    function supply(uint256 wbnbAmount) external nonReentrant returns (uint256 sharesMinted) {
        accrueInterest();
        uint256 assetsBefore = _totalAssets();
        wbnb.safeTransferFrom(msg.sender, address(this), wbnbAmount);

        // Virtual shares/assets make the first-depositor donation/inflation
        // attack economically pointless (see VIRTUAL_SHARES NatSpec above).
        sharesMinted = (wbnbAmount * (totalSupplyShares + VIRTUAL_SHARES)) / (assetsBefore + VIRTUAL_ASSETS);

        supplyShares[msg.sender] += sharesMinted;
        totalSupplyShares += sharesMinted;
        emit Supplied(msg.sender, wbnbAmount, sharesMinted);
    }

    function redeem(uint256 shareAmount) external nonReentrant returns (uint256 wbnbAmount) {
        accrueInterest();
        uint256 assets = _totalAssets();
        wbnbAmount = (shareAmount * (assets + VIRTUAL_ASSETS)) / (totalSupplyShares + VIRTUAL_SHARES);

        uint256 cash = wbnb.balanceOf(address(this));
        if (wbnbAmount > cash) revert InsufficientLiquidity();

        supplyShares[msg.sender] -= shareAmount; // reverts on underflow if over-redeeming
        totalSupplyShares -= shareAmount;

        wbnb.safeTransfer(msg.sender, wbnbAmount);
        emit Redeemed(msg.sender, wbnbAmount, shareAmount);
    }

    // ---------------------------------------------------------------------
    // Borrow side
    // ---------------------------------------------------------------------

    function depositCollateral(uint256 vaultShareAmount, address onBehalfOf) external nonReentrant {
        collateralToken.safeTransferFrom(msg.sender, address(this), vaultShareAmount);
        borrowers[onBehalfOf].collateralShares += vaultShareAmount;
        emit CollateralDeposited(onBehalfOf, msg.sender, vaultShareAmount);
    }

    /// @notice Removes vault shares posted as collateral.
    /// @dev The operator delegation is deliberately NARROW. An operator is a
    ///      contract acting for the borrower (today: the leverage zap), and an
    ///      unscoped "withdraw anyone's collateral to any address" is a drain
    ///      waiting for a compromised operator: every borrower who ever
    ///      approved one would be drained in a single call.
    ///      So an operator may ONLY pull collateral when the position carries
    ///      no debt — that is, as part of closing it — and only into its own
    ///      hands. While there is debt outstanding, only the borrower may
    ///      reduce their own collateral, and the usual LTV check still
    ///      applies on top.
    function withdrawCollateral(uint256 vaultShareAmount, address onBehalfOf, address to) external nonReentrant {
        _checkAuthorized(onBehalfOf);
        accrueInterest();

        BorrowerInfo storage info = borrowers[onBehalfOf];
        uint256 debt = _currentDebt(info);

        if (msg.sender != onBehalfOf) {
            if (debt > 0) revert OperatorCannotActOnLiveDebt();
            if (to != msg.sender) revert OperatorCannotWithdrawCollateral();
        }

        info.collateralShares -= vaultShareAmount; // reverts on underflow

        if (debt > 0) {
            uint256 remainingCollateralValue = _collateralValueInWbnb(info.collateralShares);
            if ((remainingCollateralValue * maxLtvBps) / MAX_BPS < debt) revert ExceedsLtv();
        }

        collateralToken.safeTransfer(to, vaultShareAmount);
        emit CollateralWithdrawn(onBehalfOf, to, vaultShareAmount);
    }

    /// @notice Borrows WBNB against the caller's posted collateral.
    /// @dev Same scoping rule as `withdrawCollateral`: an operator may only
    ///      borrow into its OWN hands. "Borrow on the user's behalf and send
    ///      the money anywhere" is exactly the power that turns a compromised
    ///      operator into a drain of every borrower who approved it. The
    ///      leverage zap legitimately needs this: it borrows to itself to pay
    ///      the flash principal back to the pair.
    function borrow(uint256 wbnbAmount, address onBehalfOf, address to) external nonReentrant {
        if (borrowingPaused) revert BorrowingIsPaused();
        _checkAuthorized(onBehalfOf);
        if (msg.sender != onBehalfOf && to != msg.sender) revert OperatorCannotBorrowForOthers();
        accrueInterest();

        uint256 cash = wbnb.balanceOf(address(this));
        if (wbnbAmount > cash) revert InsufficientLiquidity();

        BorrowerInfo storage info = borrowers[onBehalfOf];
        uint256 newDebt = _currentDebt(info) + wbnbAmount;

        uint256 collateralValue = _collateralValueInWbnb(info.collateralShares);
        if ((collateralValue * maxLtvBps) / MAX_BPS < newDebt) revert ExceedsLtv();

        info.principal = newDebt;
        info.indexSnapshot = borrowIndex;
        totalBorrows += wbnbAmount;

        wbnb.safeTransfer(to, wbnbAmount);
        emit Borrowed(onBehalfOf, to, wbnbAmount);
    }

    /// @notice Anyone may repay any borrower's debt (permissionless, generous
    ///         — same model as every major lending protocol).
    function repay(uint256 wbnbAmount, address onBehalfOf) external nonReentrant returns (uint256 actualRepaid) {
        accrueInterest();
        BorrowerInfo storage info = borrowers[onBehalfOf];
        uint256 debt = _currentDebt(info);
        actualRepaid = wbnbAmount > debt ? debt : wbnbAmount;
        if (actualRepaid == 0) return 0;

        wbnb.safeTransferFrom(msg.sender, address(this), actualRepaid);

        info.principal = debt - actualRepaid;
        info.indexSnapshot = borrowIndex;
        _decreaseTotalBorrows(actualRepaid);

        emit Repaid(onBehalfOf, msg.sender, actualRepaid);
    }

    function _collateralValueInWbnb(uint256 vaultShares) internal view returns (uint256) {
        if (vaultShares == 0) return 0;
        uint256 lpAmount = vault.convertToAssets(vaultShares);
        return oracle.fairValueOfLpInWbnb(lpAmount);
    }

    /// @dev Decrements the aggregate borrow, saturating at zero.
    ///      `totalBorrows` is the aggregate of the index-based borrower debts,
    ///      and the two can differ by a few wei: the per-borrower debt is
    ///      `p * I / I_i` and the aggregate is scaled by the index, so each
    ///      truncation rounds slightly differently. That is dust — but a
    ///      reverting subtraction turns dust into an UNPAYABLE debt, which is
    ///      how `repay()` and `liquidate()` used to brick themselves after
    ///      the first interest accrual. A borrower must always be able to
    ///      repay; if the aggregate is a wei short, it goes to zero.
    function _decreaseTotalBorrows(uint256 amount) internal {
        if (amount >= totalBorrows) {
            totalBorrows = 0;
        } else {
            totalBorrows -= amount;
        }
    }

    /// @notice 1e18-scaled health factor: >=1e18 is safe, <1e18 is liquidatable.
    ///         Returns type(uint256).max for borrowers with no debt.
    function healthFactor(address borrower) public view returns (uint256) {
        BorrowerInfo storage info = borrowers[borrower];
        uint256 debt = _currentDebt(info);
        if (debt == 0) return type(uint256).max;
        uint256 collateralValue = _collateralValueInWbnb(info.collateralShares);
        return Math.mulDiv(Math.mulDiv(collateralValue, liquidationThresholdBps, MAX_BPS), WAD, debt);
    }

    // ---------------------------------------------------------------------
    // Liquidation — permissionless, another job suited to an automated agent.
    // ---------------------------------------------------------------------

    function liquidate(address borrower, uint256 repayAmount)
        external
        nonReentrant
        returns (uint256 actualRepaid, uint256 collateralSeized)
    {
        accrueInterest();
        BorrowerInfo storage info = borrowers[borrower];
        uint256 debt = _currentDebt(info);
        if (healthFactor(borrower) >= 1e18) revert NotUndercollateralized();

        // Close factor: one liquidation may repay at most half of the debt.
        // The liquidator receives vault shares, not the LP, so it is exposed
        // to the collateral's price for the whole position it takes — a
        // sandwich around a full liquidation can make the seizure worth less
        // than the repayment. Bounding the debt per round bounds that
        // exposure. A position whose debt is already dust is cleared in one
        // go, so the close factor can never strand bad debt.
        uint256 maxRepay = debt <= DUST_DEBT ? debt : Math.mulDiv(debt, MAX_CLOSE_FACTOR_BPS, MAX_BPS);
        actualRepaid = repayAmount > maxRepay ? maxRepay : repayAmount;
        wbnb.safeTransferFrom(msg.sender, address(this), actualRepaid);

        info.principal = debt - actualRepaid;
        info.indexSnapshot = borrowIndex;
        _decreaseTotalBorrows(actualRepaid);

        uint256 collateralValue = _collateralValueInWbnb(info.collateralShares);
        // Round the seizure value UP (Math.Rounding.Ceil): the liquidation
        // bonus is owed to the liquidator, and truncating it would silently
        // shave the bonus and leave the protocol short. The share count below
        // is rounded DOWN instead, so the borrower never loses more
        // collateral than the bonus entitles them to.
        uint256 seizeValueInWbnb = Math.mulDiv(actualRepaid, MAX_BPS + liquidationBonusBps, MAX_BPS, Math.Rounding.Ceil);

        // Proportional slice of the borrower's collateral shares worth
        // `seizeValueInWbnb`, capped at what they actually have left (if the
        // position is deep enough underwater that this cap binds, the
        // protocol is left with uncovered bad debt — see contract header).
        collateralSeized =
            collateralValue == 0 ? 0 : Math.mulDiv(info.collateralShares, seizeValueInWbnb, collateralValue);
        if (collateralSeized > info.collateralShares) collateralSeized = info.collateralShares;

        info.collateralShares -= collateralSeized;
        collateralToken.safeTransfer(msg.sender, collateralSeized);

        emit Liquidated(borrower, msg.sender, actualRepaid, collateralSeized);
    }

    // ---------------------------------------------------------------------
    // Owner controls — risk params only, hard-capped; never touches user
    // balances, the oracle, or the vault address (both immutable).
    // ---------------------------------------------------------------------

    function setRiskParams(
        uint256 maxLtvBps_,
        uint256 liquidationThresholdBps_,
        uint256 liquidationBonusBps_,
        uint256 reserveFactorBps_
    ) external onlyOwner {
        if (liquidationThresholdBps_ > MAX_LIQUIDATION_THRESHOLD_BPS) {
            revert RiskParamOutOfRange();
        }
        if (liquidationBonusBps_ > MAX_LIQUIDATION_BONUS_BPS) revert RiskParamOutOfRange();
        if (reserveFactorBps_ > MAX_RESERVE_FACTOR_BPS) revert RiskParamOutOfRange();
        if (maxLtvBps_ + LTV_SAFETY_BUFFER_BPS > liquidationThresholdBps_) revert RiskParamOutOfRange();

        maxLtvBps = maxLtvBps_;
        liquidationThresholdBps = liquidationThresholdBps_;
        liquidationBonusBps = liquidationBonusBps_;
        reserveFactorBps = reserveFactorBps_;
        emit RiskParamsUpdated();
    }

    function setInterestRateModel(uint256 baseRateBpsPerYear, uint256 multiplierBpsPerYear) external onlyOwner {
        if (baseRateBpsPerYear > 1_000) revert RateModelOutOfRange(); // hard cap 10%/yr
        if (multiplierBpsPerYear > 10_000) revert RateModelOutOfRange(); // hard cap 100%/yr
        baseRatePerSecond = (baseRateBpsPerYear * BPS_TO_WAD_PER_YEAR) / SECONDS_PER_YEAR;
        multiplierPerSecond = (multiplierBpsPerYear * BPS_TO_WAD_PER_YEAR) / SECONDS_PER_YEAR;
        emit RiskParamsUpdated();
    }

    function setBorrowingPaused(bool paused_) external onlyOwner {
        borrowingPaused = paused_;
        emit BorrowingPausedSet(paused_);
    }

    /// @notice Withdraws protocol revenue (the reserve factor) to `to`.
    /// @dev The reserve is deliberately OUTSIDE the suppliers' claim
    ///      (`_totalAssets() = cash + totalBorrows - totalReserves`), so
    ///      withdrawing it leaves the suppliers' claim untouched — the
    ///      `amount` cancels out of `_totalAssets()` on both sides.
    ///      The amount is capped twice: by the accrued reserve, and by the
    ///      WBNB actually held. Reserves accrue while the same WBNB may be
    ///      lent out, so the two balances can diverge; without the cash cap
    ///      this call would revert once reserves exceed the balance.
    function withdrawReserves(uint256 amount, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        accrueInterest();
        uint256 cash = wbnb.balanceOf(address(this));
        if (amount > totalReserves) amount = totalReserves;
        if (amount > cash) amount = cash;
        totalReserves -= amount;
        wbnb.safeTransfer(to, amount);
        emit ReservesWithdrawn(amount, to);
    }
}
