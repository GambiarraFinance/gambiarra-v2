// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {GambLendingPool} from "../src/GambLendingPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice Unit tests for GambLendingPool's supply/borrow/collateral/liquidation
///         mechanics and the virtual-shares inflation guard.
contract GambLendingPoolTest is Test {
    MockERC20 wbnb;
    MockVault vault;
    MockOracle oracle;
    GambLendingPool pool;

    address alice = address(0xA11CE);
    address bob = address(0xB0B);
    address attacker = address(0xBAD);
    address liquidator = address(0x1111);

    function setUp() public {
        wbnb = new MockERC20("Wrapped BNB", "WBNB");
        vault = new MockVault(wbnb);
        oracle = new MockOracle();
        pool = new GambLendingPool(wbnb, vault, oracle, address(this));

        wbnb.mint(alice, 1_000e18);
        wbnb.mint(bob, 1_000e18);
        wbnb.mint(attacker, 100e18);
        wbnb.mint(liquidator, 1_000e18);

        vm.prank(alice);
        wbnb.approve(address(pool), type(uint256).max);
        vm.prank(bob);
        wbnb.approve(address(pool), type(uint256).max);
        vm.prank(attacker);
        wbnb.approve(address(pool), type(uint256).max);
        vm.prank(liquidator);
        wbnb.approve(address(pool), type(uint256).max);

        vm.prank(bob);
        vault.approve(address(pool), type(uint256).max);
        vm.prank(attacker);
        vault.approve(address(pool), type(uint256).max);
    }

    function _supply(address who, uint256 amount) internal returns (uint256 shares) {
        vm.prank(who);
        shares = pool.supply(amount);
    }

    function _collateralize(address who, uint256 shares) internal {
        vm.prank(who);
        pool.depositCollateral(shares, who);
    }

    // ------------------------------------------------------------------
    // Supply / redeem
    // ------------------------------------------------------------------

    function test_supplyAndRedeem_roundTrip() public {
        uint256 shares = _supply(alice, 100e18);
        assertGt(shares, 0);
        assertEq(pool.totalSupplyShares(), shares);
        assertEq(pool.supplyShares(alice), shares);

        vm.prank(alice);
        uint256 out = pool.redeem(shares);

        assertEq(out, 100e18, "round trip should return the deposited amount");
        assertEq(pool.totalSupplyShares(), 0);
        assertEq(wbnb.balanceOf(alice), 1_000e18);
    }

    function test_firstDepositorInflationAttackIsUnprofitable() public {
        // Attacker supplies 1 wei, then donates WBNB directly to the pool to
        // inflate the share price before the victim deposits.
        _supply(attacker, 1);
        vm.prank(attacker);
        wbnb.transfer(address(pool), 10e18);

        uint256 victimShares = _supply(alice, 1e18);
        assertGt(victimShares, 0, "victim must receive non-zero shares");

        vm.prank(alice);
        uint256 victimOut = pool.redeem(victimShares);
        // Virtual-shares rounding costs the victim a negligible fraction of a
        // basis point; the attack itself must not be able to zero them out.
        assertGe(victimOut, 0.999e18, "victim must keep essentially their whole deposit");

        // Attacker should end up with less than their 1 wei + 10e18 donation.
        uint256 attackerShares = pool.supplyShares(attacker);
        vm.prank(attacker);
        uint256 attackerOut = pool.redeem(attackerShares);
        assertLt(attackerOut, 10e18 + 1, "attack must be unprofitable");
    }

    // ------------------------------------------------------------------
    // Collateral / borrow / LTV
    // ------------------------------------------------------------------

    function test_borrowWithinLtv() public {
        _supply(alice, 1_000e18);

        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);
        assertEq(pool.currentDebt(bob), 40e18);
        assertEq(wbnb.balanceOf(bob), 1_040e18); // 1,000 starting + 40 borrowed
    }

    function test_borrowAboveLtvReverts() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        vm.expectRevert(GambLendingPool.ExceedsLtv.selector);
        pool.borrow(41e18, bob, bob);
    }

    function test_withdrawCollateralThatBreaksLtvReverts() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        // Removing even 1 share leaves 99 * 40% = 39.6 WBNB of borrowing power.
        vm.prank(bob);
        vm.expectRevert(GambLendingPool.ExceedsLtv.selector);
        pool.withdrawCollateral(1e18, bob, bob);
    }

    // ------------------------------------------------------------------
    // Interest + liquidation
    // ------------------------------------------------------------------

    function test_interestAccruesOverTime() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest();

        assertGt(pool.currentDebt(bob), 40e18, "debt must grow with interest");
        assertGt(pool.totalReserves(), 0, "protocol must book reserves");
    }

    function test_repayFullDebtAfterAccrualDoesNotUnderflow() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest();

        uint256 debt = pool.currentDebt(bob);
        vm.prank(bob);
        uint256 repaid = pool.repay(debt, bob);

        assertEq(repaid, debt, "full debt must be repaid");
        assertEq(pool.currentDebt(bob), 0, "borrower must be debt-free");
        assertEq(pool.totalBorrows(), 0, "global borrows must not underflow");
    }

    function test_liquidateFullDebtAfterAccrualDoesNotUnderflow() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        vm.warp(block.timestamp + 30 days);
        pool.accrueInterest();

        oracle.setPriceWad(0.1e18); // deeply underwater
        uint256 debt = pool.currentDebt(bob);

        vm.prank(liquidator);
        (uint256 repaid,) = pool.liquidate(bob, debt);

        assertEq(repaid, debt);
        assertEq(pool.currentDebt(bob), 0);
        assertEq(pool.totalBorrows(), 0);
    }

    function test_liquidateUndercollateralizedPosition() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        // Collateral value halves: 100 LP * 0.5 WBNB = 50 WBNB.
        // Health factor = 50 * 50% / 40 = 0.625.
        oracle.setPriceWad(0.5e18);
        assertLt(pool.healthFactor(bob), 1e18);

        vm.prank(liquidator);
        (uint256 repaid, uint256 seized) = pool.liquidate(bob, 20e18);

        assertEq(repaid, 20e18);
        // 20 * 1.1 / 0.5 = 44 shares.
        assertEq(seized, 44e18);
        assertEq(vault.balanceOf(liquidator), 44e18);
        assertEq(pool.currentDebt(bob), 20e18);
    }

    function test_liquidateHealthyPositionReverts() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        vm.prank(liquidator);
        vm.expectRevert(GambLendingPool.NotUndercollateralized.selector);
        pool.liquidate(bob, 20e18);
    }

    // ------------------------------------------------------------------
    // Operator delegation is scoped
    // ------------------------------------------------------------------
    //
    // An operator is a contract acting for the borrower (today: the leverage
    // zap). An unscoped delegation is a drain: "borrow for the user and send
    // the money anywhere" or "withdraw the user's collateral to anywhere"
    // means a compromised operator empties every borrower who ever approved
    // it. The operator may only act into its own hands, and may only pull
    // collateral out of a position that carries no debt.

    function test_operatorCannotBorrowToAThirdParty() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.approveOperator(attacker);

        // The operator may borrow, but only into its own hands. Sending it
        // anywhere else is a drain of the borrower's credit line.
        vm.prank(attacker);
        vm.expectRevert(GambLendingPool.OperatorCannotBorrowForOthers.selector);
        pool.borrow(10e18, bob, liquidator);
    }

    function test_operatorCanBorrowIntoItsOwnHands() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.approveOperator(attacker);

        vm.prank(attacker);
        pool.borrow(10e18, bob, attacker);

        assertEq(wbnb.balanceOf(attacker), 100e18 + 10e18, "the operator keeps the WBNB it borrowed");
        assertEq(pool.currentDebt(bob), 10e18, "the debt is the borrower's");
    }

    function test_operatorCannotWithdrawCollateralToAThirdParty() public {
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.approveOperator(attacker);

        vm.prank(attacker);
        vm.expectRevert(GambLendingPool.OperatorCannotWithdrawCollateral.selector);
        pool.withdrawCollateral(50e18, bob, liquidator);
    }

    function test_operatorCannotWithdrawCollateralWhileDebtIsLive() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        vm.prank(bob);
        pool.approveOperator(attacker);

        // The operator may not take the collateral out from under a live debt
        // — not even into its own hands.
        vm.prank(attacker);
        vm.expectRevert(GambLendingPool.OperatorCannotActOnLiveDebt.selector);
        pool.withdrawCollateral(50e18, bob, attacker);
    }

    function test_operatorCanWithdrawCollateralAfterTheDebtIsCleared() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(40e18, bob, bob);

        vm.prank(bob);
        pool.approveOperator(attacker);

        // Repay, then the operator may pull the collateral to itself: this is
        // exactly what closing a position looks like.
        vm.startPrank(bob);
        wbnb.approve(address(pool), type(uint256).max);
        pool.repay(pool.currentDebt(bob), bob);
        vm.stopPrank();

        vm.prank(attacker);
        pool.withdrawCollateral(100e18, bob, attacker);

        assertEq(vault.balanceOf(attacker), 100e18, "the operator received the collateral");
        (,, uint256 remainingShares) = pool.borrowers(bob);
        assertEq(remainingShares, 0, "the position is closed");
    }

    function test_borrowerKeepsFullControlOverItsOwnCollateral() public {
        _supply(alice, 1_000e18);
        vault.mintShares(bob, 100e18);
        _collateralize(bob, 100e18);

        vm.prank(bob);
        pool.borrow(30e18, bob, bob);

        // The borrower may still borrow into any address it chooses.
        vm.prank(bob);
        pool.borrow(1e18, bob, bob);
        assertEq(wbnb.balanceOf(bob), 1_000e18 + 31e18);

        // And may withdraw its own collateral, subject to the LTV check.
        vm.prank(bob);
        pool.withdrawCollateral(10e18, bob, bob);
        assertEq(vault.balanceOf(bob), 10e18, "the withdrawn collateral came back to the borrower");
        (,, uint256 posted) = pool.borrowers(bob);
        assertEq(posted, 90e18, "the rest is still posted as collateral");
    }
}
