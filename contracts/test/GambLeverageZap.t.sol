// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GambLeverageZap} from "../src/GambLeverageZap.sol";
import {GambLendingPool} from "../src/GambLendingPool.sol";
import {IPancakeFlashPair} from "../src/interfaces/IPancakeFlashPair.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";

import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPairERC20} from "./mocks/MockPairERC20.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {MockOracle} from "./mocks/MockOracle.sol";
import {MockFlashPair} from "./mocks/MockFlashPair.sol";

/// @notice Unit tests for GambLeverageZap — the open/close orchestration that
///         the fork suite exercises against the REAL flash pair and router.
///         These cover what a fork run cannot afford to probe: every leverage
///         boundary, the pause/authorization rules and the pull paths, all
///         deterministically and without touching mainnet.
/// @dev The zap is pure orchestration: a mock flash pair lends WBNB, the mock
///      router swaps and mints LP, the mock vault mints shares 1:1 with LP, and
///      the lending pool takes those shares as collateral. The one number that
///      matters is the Oracle price: 1 LP redeems for 2 WBNB on a balanced
///      pair, so the mock vault's 1:1 shares are valued at 2x.
contract GambLeverageZapTest is Test {
    MockERC20 wbnb;
    MockERC20 gamb;
    MockPairERC20 lp;
    MockRouter router;
    MockVault vault;
    MockOracle oracle;
    GambLendingPool pool;
    MockFlashPair flashPair;
    GambLeverageZap zap;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);

    function setUp() public {
        wbnb = new MockERC20("Wrapped BNB", "WBNB");
        gamb = new MockERC20("Gambiarra", "GAMB");
        lp = new MockPairERC20("GAMB/WBNB LP", "GAMB-WBNB", address(gamb), address(wbnb));

        router = new MockRouter(lp);
        vault = new MockVault(IERC20(address(lp)));
        oracle = new MockOracle();
        // A balanced pair: 1 LP unit redeems for roughly 2 WBNB. The mock
        // vault is 1 share : 1 LP, so this is the price the pool must see.
        oracle.setPriceWad(2e18);
        pool = new GambLendingPool(IERC20(address(wbnb)), vault, oracle, address(this));

        flashPair = new MockFlashPair(address(wbnb), address(gamb)); // token0 = WBNB
        flashPair.setFlashToken(address(wbnb));

        zap = new GambLeverageZap(
            IERC20(address(wbnb)),
            IERC20(address(gamb)),
            IERC20(address(lp)),
            IPancakeRouter02(address(router)),
            vault,
            pool,
            IPancakeFlashPair(address(flashPair)),
            address(this)
        );

        // Fund the pool so there is real WBNB to borrow through the flash.
        wbnb.mint(address(this), 1_000e18);
        wbnb.approve(address(pool), type(uint256).max);
        pool.supply(1_000e18);

        wbnb.mint(alice, 100e18);
        wbnb.mint(bob, 100e18);
        vm.startPrank(alice);
        wbnb.approve(address(zap), type(uint256).max);
        pool.approveOperator(address(zap));
        vm.stopPrank();
        vm.startPrank(bob);
        wbnb.approve(address(zap), type(uint256).max);
        pool.approveOperator(address(zap));
        vm.stopPrank();
    }

    /// @dev Keep the pair's reserves proportional to the LP supply so the zap's
    ///      reserve-based `removeLiquidity` minimums line up with the mock
    ///      router's even split. A real pair maintains this by construction.
    function _syncReserves() internal {
        uint112 r = uint112(lp.totalSupply() / 2);
        lp.setReserves(r, r);
    }

    function _open(address who, uint256 principal, uint256 leverageBps) internal {
        vm.prank(who);
        zap.openLeveragedPosition(principal, leverageBps, 0, block.timestamp + 1 hours);
    }

    // ------------------------------------------------------------------
    // Happy path
    // ------------------------------------------------------------------

    function test_openThenClose_roundTripLeavesTheZapEmpty() public {
        uint256 principal = 10e18;
        uint256 leverageBps = 14_000; // 1.4x, safely under the derived cap

        _open(alice, principal, leverageBps);

        (uint256 debt,, uint256 collateral) = pool.borrowers(alice);
        assertGt(debt, 0, "a leveraged position must carry debt");
        assertGt(collateral, 0, "collateral must be recorded under the user");
        assertEq(collateral, vault.balanceOf(address(pool)), "the pool holds the shares, not the zap");

        // The zap must never custody anything between transactions.
        assertEq(lp.balanceOf(address(zap)), 0, "no LP may idle in the zap");
        assertEq(vault.balanceOf(address(zap)), 0, "no vault shares may idle in the zap");
        assertEq(wbnb.balanceOf(address(zap)), 0, "no WBNB may idle in the zap");
        assertEq(gamb.balanceOf(address(zap)), 0, "no GAMB may idle in the zap");

        // Close.
        _syncReserves();
        uint256 wbnbBefore = wbnb.balanceOf(alice);
        vm.prank(alice);
        zap.closeLeveragedPosition(0, block.timestamp + 1 hours);

        (uint256 debtAfter,, uint256 sharesAfter) = pool.borrowers(alice);
        assertEq(debtAfter, 0, "closing must clear the debt");
        assertEq(sharesAfter, 0, "closing must pull the collateral back");
        assertGt(wbnb.balanceOf(alice), wbnbBefore, "the leftover WBNB must come back to the user");
        assertEq(lp.balanceOf(address(zap)), 0, "the zap must end empty");
        assertEq(vault.balanceOf(address(zap)), 0, "the zap must end with no shares");
    }

    // ------------------------------------------------------------------
    // Leverage ceiling — derived from the pool's LTV, not hardcoded
    // ------------------------------------------------------------------

    /// @dev With the default 40% LTV the exact break-even is 1/(1-0.4) = 1.6667x
    ///      and the 10% margin lands on 14999 bps. Pin both sides of the line.
    function test_leverageCeilingIsDerivedFromThePoolLtv() public {
        _open(alice, 1e18, 14_999); // just inside
        assertGt(pool.currentDebt(alice), 0, "the maximum derived leverage must be reachable");

        vm.expectRevert(GambLeverageZap.BadLeverage.selector);
        _open(bob, 1e18, 15_000); // one bp over

        vm.expectRevert(GambLeverageZap.BadLeverage.selector);
        _open(bob, 1e18, 30_000); // the absolute 3x ceiling is still too high
    }

    function test_leverageCeilingFollowsThePoolLtv() public {
        // Raise the pool's LTV to 50% (threshold 60% keeps the 5% buffer).
        pool.setRiskParams(5_000, 6_000, 1_000, 1_000);

        _open(alice, 1e18, 18_000); // 1/(1-0.5)=2x, minus margin -> 18000
        assertGt(pool.currentDebt(alice), 0, "a higher LTV must unlock more leverage");

        vm.expectRevert(GambLeverageZap.BadLeverage.selector);
        _open(bob, 1e18, 18_001);
    }

    function test_leverageOfOneOrBelowIsRejected() public {
        vm.expectRevert(GambLeverageZap.BadLeverage.selector);
        _open(alice, 1e18, 10_000); // exactly 1x is not leverage

        vm.expectRevert(GambLeverageZap.BadLeverage.selector);
        _open(alice, 1e18, 5_000);
    }

    // ------------------------------------------------------------------
    // Guards: pause, deadline, zero, callback auth
    // ------------------------------------------------------------------

    function test_pauseBlocksOpeningButNeverClosing() public {
        _open(alice, 5e18, 12_000);

        zap.setOpeningPaused(true);

        vm.expectRevert(GambLeverageZap.OpeningIsPaused.selector);
        _open(bob, 5e18, 12_000);

        // An existing position must always be closeable.
        _syncReserves();
        vm.prank(alice);
        zap.closeLeveragedPosition(0, block.timestamp + 1 hours);
        (uint256 debt,, uint256 shares) = pool.borrowers(alice);
        assertEq(debt, 0, "closing must survive a paused zap");
        assertEq(shares, 0, "collateral must come back");
    }

    function test_openRejectsExpiredDeadlineAndZeroPrincipal() public {
        vm.expectRevert(GambLeverageZap.DeadlineExpired.selector);
        vm.prank(alice);
        zap.openLeveragedPosition(1e18, 12_000, 0, block.timestamp - 1);

        vm.expectRevert(GambLeverageZap.ZeroAmount.selector);
        _open(alice, 0, 12_000);
    }

    function test_closeRejectsExpiredDeadline() public {
        _open(alice, 5e18, 12_000);

        vm.prank(alice);
        vm.expectRevert(GambLeverageZap.DeadlineExpired.selector);
        zap.closeLeveragedPosition(0, block.timestamp - 1);
    }

    function test_closeWithoutAPositionReverts() public {
        vm.prank(alice);
        vm.expectRevert(GambLeverageZap.NoPosition.selector);
        zap.closeLeveragedPosition(0, block.timestamp + 1 hours);
    }

    function test_flashCallbackOnlyFromTheFlashPair() public {
        vm.expectRevert(GambLeverageZap.BadFlashCaller.selector);
        zap.pancakeCall(address(this), 0, 0, "");
    }

    function test_closeEnforcesMinWbnbOut() public {
        _open(alice, 5e18, 12_000);

        _syncReserves();
        vm.prank(alice);
        vm.expectRevert(GambLeverageZap.SlippageExceeded.selector);
        zap.closeLeveragedPosition(type(uint256).max, block.timestamp + 1 hours);
    }

    // ------------------------------------------------------------------
    // Owner surface
    // ------------------------------------------------------------------

    function test_setSwapSlippageIsBounded() public {
        vm.expectRevert(bytes("out of range"));
        zap.setSwapSlippageBps(10);
        vm.expectRevert(bytes("out of range"));
        zap.setSwapSlippageBps(600);

        zap.setSwapSlippageBps(200);
        assertEq(zap.swapSlippageBps(), 200);
    }

    function test_rescueTokenCanNeverTouchProtocolAssets() public {
        MockERC20 other = new MockERC20("Stray", "STRAY");
        other.mint(address(zap), 1e18);

        vm.expectRevert(GambLeverageZap.CannotRescueProtocolAsset.selector);
        zap.rescueToken(address(wbnb), 1, address(this));
        vm.expectRevert(GambLeverageZap.CannotRescueProtocolAsset.selector);
        zap.rescueToken(address(gamb), 1, address(this));
        vm.expectRevert(GambLeverageZap.CannotRescueProtocolAsset.selector);
        zap.rescueToken(address(lp), 1, address(this));
        vm.expectRevert(GambLeverageZap.CannotRescueProtocolAsset.selector);
        zap.rescueToken(address(vault), 1, address(this));

        zap.rescueToken(address(other), 1e18, address(this));
        assertEq(other.balanceOf(address(this)), 1e18, "a stray token must be recoverable");
    }
}
