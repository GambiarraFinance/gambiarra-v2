// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ERC4626} from "@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol";

import {GambVault} from "../src/GambVault.sol";
import {IGambMasterChef} from "../src/interfaces/IGambMasterChef.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockMasterChef} from "./mocks/MockMasterChef.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

/// @notice Unit tests for GambVault — the ERC4626 that actually custodies user
///         funds. The fork suite covers the same paths against the REAL
///         MasterChef and the real LP pair; these cover the paths a fork
///         cannot: a broken MasterChef, and the rescue path.
contract GambVaultTest is Test {
    MockERC20 lp;
    MockERC20 gamb;
    MockERC20 wbnb;
    MockMasterChef masterChef;
    MockRouter router;
    GambVault vault;

    address alice = address(0xA11CE);
    address keeper = address(0xCAFE);
    address feeRecipient = address(0xFEE);
    uint256 constant PID = 25;

    function setUp() public {
        lp = new MockERC20("GAMB/WBNB LP", "GAMB-WBNB-LP");
        gamb = new MockERC20("Gambiarra", "GAMB");
        wbnb = new MockERC20("Wrapped BNB", "WBNB");

        masterChef = new MockMasterChef(address(lp));
        masterChef.setGambToken(address(gamb));
        router = new MockRouter(lp);

        vault = new GambVault(
            IERC20(address(lp)),
            IGambMasterChef(address(masterChef)),
            PID,
            IERC20(address(gamb)),
            IERC20(address(wbnb)),
            IPancakeRouter02(address(router)),
            address(this),
            feeRecipient
        );

        lp.mint(alice, 1_000e18);
        vm.prank(alice);
        lp.approve(address(vault), type(uint256).max);
    }

    function _stakedLp() internal view returns (uint256) {
        (uint256 staked,) = masterChef.userInfo(PID, address(vault));
        return staked;
    }

    function _queueReward(uint256 amount) internal {
        gamb.mint(address(masterChef), amount);
        masterChef.setPendingGamb(PID, address(vault), amount);
    }

    function _deposit(uint256 amount) internal returns (uint256) {
        vm.prank(alice);
        return vault.deposit(amount, alice);
    }

    // ------------------------------------------------------------------
    // Deposit / withdraw
    // ------------------------------------------------------------------

    function test_depositStakesEverything() public {
        uint256 shares = _deposit(100e18);
        assertGt(shares, 0);
        assertEq(lp.balanceOf(address(vault)), 0, "no LP may idle in the vault");
        assertEq(_stakedLp(), 100e18, "100% of the deposit must be staked");
    }

    function test_withdrawUnstakesAndReturnsLp() public {
        uint256 shares = _deposit(100e18);

        vm.prank(alice);
        uint256 assets = vault.redeem(shares, alice, alice);

        assertApproxEqAbs(assets, 100e18, 2, "redeem must return the deposit");
        assertEq(_stakedLp(), 0, "nothing may stay staked");
        assertEq(lp.balanceOf(alice), 1_000e18, "the LP came back");
    }

    function test_totalAssetsCountsStakedAndIdle() public {
        assertEq(vault.totalAssets(), 0);
        _deposit(100e18);
        assertEq(vault.totalAssets(), 100e18);
        lp.mint(address(vault), 5e18);
        assertEq(vault.totalAssets(), 105e18, "idle LP counts too");
    }

    // ------------------------------------------------------------------
    // Harvest
    // ------------------------------------------------------------------

    function test_harvestPaysFeeAndCallerIncentiveAndRestakes() public {
        _deposit(100e18);
        _queueReward(100e18);

        vm.prank(keeper);
        uint256 lpCompounded = vault.harvest(0, block.timestamp + 1 hours);

        uint256 fee = (100e18 * vault.performanceFeeBps()) / 10_000;
        uint256 incentive = (100e18 * vault.callerIncentiveBps()) / 10_000;
        assertEq(gamb.balanceOf(feeRecipient), fee, "the performance fee must be paid");
        assertEq(gamb.balanceOf(keeper), incentive, "the caller incentive must be paid");

        // 100 - 5 - 0.5 = 94.5 GAMB compounded, half swapped, half pooled.
        assertEq(lpCompounded, 47.25e18, "the compounded LP");
        assertEq(lp.balanceOf(address(vault)), 0, "the compounded LP must be restaked, not idle");
        assertEq(_stakedLp(), 147.25e18, "the compounded LP is restaked on top of the original stake");
    }

    function test_harvestRevertsWithExpiredDeadline() public {
        _deposit(100e18);
        _queueReward(100e18);

        vm.expectRevert(GambVault.DeadlineExpired.selector);
        vault.harvest(0, block.timestamp - 1);
    }

    function test_harvestRevertsWhenMinLpOutIsNotMet() public {
        _deposit(100e18);
        _queueReward(100e18);

        vm.expectRevert(GambVault.SlippageExceeded.selector);
        vault.harvest(1_000e18, block.timestamp + 1 hours);
    }

    /// @dev The regression that used to brick harvest() forever: a dust reward
    ///      splits into a zero-amount swap leg, which the router rejects.
    function test_harvestWithDustRewardDoesNotBrick() public {
        _deposit(100e18);
        _queueReward(1);

        vm.prank(keeper);
        uint256 compounded = vault.harvest(0, block.timestamp + 1 hours);
        assertEq(compounded, 0, "dust cannot be compounded");

        // The next harvest must still work.
        _queueReward(100e18);
        vm.prank(keeper);
        assertGt(vault.harvest(0, block.timestamp + 1 hours), 0, "harvest must still work after dust");
    }

    // ------------------------------------------------------------------
    // Emergency exit
    // ------------------------------------------------------------------

    /// @dev The rescue must not burn the depositors' accrued rewards:
    ///      `emergencyWithdraw` forfeits them, so they are collected and
    ///      compounded back into LP first, with no fee.
    function test_emergencyExitRecoversPendingRewards() public {
        _deposit(100e18);
        _queueReward(10e18);

        vault.emergencyExitMasterChef();

        assertTrue(vault.emergencyExited(), "the vault must be flagged as exited");
        assertEq(_stakedLp(), 0, "nothing may stay staked");
        // 100 LP unstaked + 5 LP compounded out of the 10 recovered GAMB.
        assertEq(lp.balanceOf(address(vault)), 105e18, "the LP and the compounded rewards are both in the vault");
        assertEq(gamb.balanceOf(address(vault)), 0, "the recovered GAMB was compounded, not stranded");
        assertEq(vault.totalAssets(), 105e18, "the depositors keep the recovered value");
    }

    /// @dev The rescue is the path of last resort: a MasterChef that cannot
    ///      even pay out must not block it.
    function test_emergencyExitStillWorksWhenTheMasterChefCannotPayOut() public {
        _deposit(100e18);
        _queueReward(10e18);
        masterChef.setDepositReverts(true);

        vault.emergencyExitMasterChef();

        assertTrue(vault.emergencyExited());
        assertEq(_stakedLp(), 0);
        assertEq(lp.balanceOf(address(vault)), 100e18, "the LP was rescued");
    }

    function test_emergencyExitCannotRunTwice() public {
        _deposit(100e18);
        vault.emergencyExitMasterChef();

        vm.expectRevert(GambVault.AlreadyExited.selector);
        vault.emergencyExitMasterChef();
    }

    function test_harvestIsDisabledAfterTheEmergencyExit() public {
        _deposit(100e18);
        vault.emergencyExitMasterChef();

        vm.expectRevert(GambVault.AlreadyExited.selector);
        vault.harvest(0, block.timestamp + 1 hours);
    }

    // ------------------------------------------------------------------
    // Owner surfaces
    // ------------------------------------------------------------------

    function test_rescueTokenCannotStealTheVaultsOwnAssets() public {
        vm.expectRevert(GambVault.CannotRescueVaultAsset.selector);
        vault.rescueToken(address(lp), 1, alice);

        vm.expectRevert(GambVault.CannotRescueVaultAsset.selector);
        vault.rescueToken(address(gamb), 1, alice);

        vm.expectRevert(GambVault.CannotRescueVaultAsset.selector);
        vault.rescueToken(address(vault), 1, alice);
    }

    function test_rescueTokenSweepsAForeignToken() public {
        MockERC20 stray = new MockERC20("Stray", "STRAY");
        stray.mint(address(vault), 42e18);

        vault.rescueToken(address(stray), 42e18, alice);
        assertEq(stray.balanceOf(alice), 42e18, "a foreign token must be sweepable");

        vm.expectRevert(GambVault.ZeroAddress.selector);
        vault.rescueToken(address(stray), 1, address(0));
    }

    function test_feeAndSlippageCapsAreEnforced() public {
        vm.expectRevert(GambVault.FeeTooHigh.selector);
        vault.setPerformanceFeeBps(1_001);

        vm.expectRevert(GambVault.IncentiveTooHigh.selector);
        vault.setCallerIncentiveBps(101);

        vm.expectRevert(GambVault.SlippageOutOfRange.selector);
        vault.setSwapSlippageBps(49);

        vm.expectRevert(GambVault.SlippageOutOfRange.selector);
        vault.setSwapSlippageBps(501);
    }

    /// @dev Deposits are pausable; withdrawals never are. The exit must not be
    ///      a lever to trap depositors.
    function test_depositsCanBePausedButWithdrawalsCannot() public {
        uint256 shares = _deposit(100e18);

        vault.setDepositsPaused(true);
        assertEq(vault.maxDeposit(alice), 0, "deposits must be blocked while paused");
        assertEq(vault.maxMint(alice), 0, "mints must be blocked while paused");

        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(ERC4626.ERC4626ExceededMaxDeposit.selector, alice, 1e18, 0));
        vault.deposit(1e18, alice);

        vm.prank(alice);
        assertGt(vault.redeem(shares, alice, alice), 0, "withdrawals must not be pausable");
    }
}
