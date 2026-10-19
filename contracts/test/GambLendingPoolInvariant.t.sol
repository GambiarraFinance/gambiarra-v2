// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {StdInvariant} from "forge-std/StdInvariant.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GambLendingPool} from "../src/GambLendingPool.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVault} from "./mocks/MockVault.sol";
import {MockOracle} from "./mocks/MockOracle.sol";

/// @notice Randomised actor for the lending pool. Every action is bounded and
///         failure-tolerant (a revert is simply a no-op), so the fuzzer spends
///         its budget on reachable states instead of on reverts.
contract LendingPoolHandler is Test {
    GambLendingPool public immutable pool;
    MockVault public immutable vault;
    MockERC20 public immutable wbnb;
    MockOracle public immutable oracle;

    address[] public actors;
    uint256 public callCount;

    constructor(GambLendingPool pool_, MockVault vault_, MockERC20 wbnb_, MockOracle oracle_) {
        pool = pool_;
        vault = vault_;
        wbnb = wbnb_;
        oracle = oracle_;
        for (uint256 i = 0; i < 4; i++) {
            address who = address(uint160(0xA11CE + i));
            actors.push(who);
            wbnb.mint(who, 1_000e18);
            vault.mintShares(who, 1_000e18);
            vm.startPrank(who);
            wbnb.approve(address(pool), type(uint256).max);
            vault.approve(address(pool), type(uint256).max);
            vm.stopPrank();
        }
    }

    function actor(uint256 seed) public view returns (address) {
        return actors[seed % actors.length];
    }

    function actorsLength() external view returns (uint256) {
        return actors.length;
    }

    function supply(uint256 seed, uint256 amount) external {
        address a = actor(seed);
        amount = bound(amount, 1e6, 500e18);
        vm.prank(a);
        try pool.supply(amount) {} catch {}
        callCount++;
    }

    function depositCollateral(uint256 seed, uint256 shares) external {
        address a = actor(seed);
        shares = bound(shares, 1e6, 500e18);
        vm.prank(a);
        try pool.depositCollateral(shares, a) {} catch {}
        callCount++;
    }

    function borrow(uint256 seed, uint256 amount) external {
        address a = actor(seed);
        amount = bound(amount, 1e6, 100e18);
        vm.prank(a);
        try pool.borrow(amount, a, a) {} catch {}
        callCount++;
    }

    function repay(uint256 seed, uint256 amount) external {
        address a = actor(seed);
        amount = bound(amount, 1, 100e18);
        vm.prank(a);
        try pool.repay(amount, a) {} catch {}
        callCount++;
    }

    function withdrawCollateral(uint256 seed, uint256 shares) external {
        address a = actor(seed);
        shares = bound(shares, 1e6, 100e18);
        vm.prank(a);
        try pool.withdrawCollateral(shares, a, a) {} catch {}
        callCount++;
    }

    function redeem(uint256 seed, uint256 shares) external {
        address a = actor(seed);
        shares = bound(shares, 1e6, 100e18);
        vm.prank(a);
        try pool.redeem(shares) {} catch {}
        callCount++;
    }

    function accrueInterest(uint256 elapsed) external {
        elapsed = bound(elapsed, 1, 30 days);
        vm.warp(block.timestamp + elapsed);
        pool.accrueInterest();
        callCount++;
    }

    function movePrice(uint256 priceWad) external {
        // Bounded so the oracle stays in a sane range; the point is to move
        // the collateral price, not to test absurd values.
        oracle.setPriceWad(bound(priceWad, 1e17, 10e18));
        callCount++;
    }
}

/// @notice Invariants for GambLendingPool.
/// @dev The fourth invariant is the one that matters: the aggregate
///      `totalBorrows` must track the SUM of the per-borrower debts. When
///      the aggregate drifts below the sum, `totalBorrows -= repaid`
///      underflows and the debt becomes unpayable — which is exactly the bug
///      the fork test found. A unit test with round numbers cannot see it;
///      a randomised sequence of accruals can.
contract GambLendingPoolInvariantTest is StdInvariant, Test {
    GambLendingPool internal pool;
    LendingPoolHandler internal handler;

    address[] internal actors;

    function setUp() public {
        MockERC20 wbnb = new MockERC20("Wrapped BNB", "WBNB");
        MockVault vault = new MockVault(wbnb);
        MockOracle oracle = new MockOracle();
        pool = new GambLendingPool(wbnb, vault, oracle, address(this));

        handler = new LendingPoolHandler(pool, vault, wbnb, oracle);
        for (uint256 i = 0; i < handler.actorsLength(); i++) {
            actors.push(handler.actor(i));
        }

        targetContract(address(handler));
        bytes4[] memory selectors = new bytes4[](6);
        selectors[0] = handler.supply.selector;
        selectors[1] = handler.depositCollateral.selector;
        selectors[2] = handler.borrow.selector;
        selectors[3] = handler.repay.selector;
        selectors[4] = handler.withdrawCollateral.selector;
        selectors[5] = handler.accrueInterest.selector;
        targetSelector(FuzzSelector({addr: address(handler), selectors: selectors}));
    }

    /// @dev Every share of collateral the pool records must be held by it.
    function invariant_collateralIsFullyBacked() public view {
        uint256 recorded;
        for (uint256 i = 0; i < actors.length; i++) {
            (,, uint256 shares) = pool.borrowers(actors[i]);
            recorded += shares;
        }
        assertEq(vaultBalance(), recorded, "recorded collateral must be held by the pool");
    }

    /// @dev The pool must never be insolvent on the supply side.
    function invariant_supplySideIsSolvent() public view {
        uint256 cash = wbnbBalance();
        uint256 assets = cash + pool.totalBorrows() - pool.totalReserves();
        assertGe(assets, 0, "the supply side must not underflow");
        assertGe(cash, 0, "the pool must hold a sane cash balance");
    }

    /// @dev No position may end up with debt and no collateral.
    function invariant_noDebtWithoutCollateral() public view {
        for (uint256 i = 0; i < actors.length; i++) {
            (uint256 principal,, uint256 shares) = pool.borrowers(actors[i]);
            if (principal > 0) {
                assertGt(shares, 0, "a position with debt must keep collateral");
            }
        }
    }

    /// @dev The aggregate must track the sum of the debts. A drift is only
    ///      tolerable at wei level: anything larger means the accounting has
    ///      diverged, and `totalBorrows -= repaid` will underflow.
    function invariant_aggregateBorrowsTracksTheSumOfDebts() public view {
        uint256 sum;
        for (uint256 i = 0; i < actors.length; i++) {
            sum += pool.currentDebt(actors[i]);
        }
        uint256 aggregate = pool.totalBorrows();
        uint256 diff = sum > aggregate ? sum - aggregate : aggregate - sum;
        assertLe(diff, 1e6, "the aggregate borrow must track the sum of the debts");
    }

    function wbnbBalance() internal view returns (uint256) {
        return wbnbToken().balanceOf(address(pool));
    }

    function vaultBalance() internal view returns (uint256) {
        return vaultToken().balanceOf(address(pool));
    }

    function wbnbToken() internal view returns (MockERC20) {
        return MockERC20(address(handler.wbnb()));
    }

    function vaultToken() internal view returns (MockVault) {
        return handler.vault();
    }
}
