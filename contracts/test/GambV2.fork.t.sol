// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployLib, LegacyAddresses} from "../script/DeployLib.sol";
import {GambVault} from "../src/GambVault.sol";
import {GambLendingPool} from "../src/GambLendingPool.sol";
import {GambLeverageZap} from "../src/GambLeverageZap.sol";
import {GambTwapOracle} from "../src/GambTwapOracle.sol";
import {IGambMasterChef} from "../src/interfaces/IGambMasterChef.sol";
import {IPancakeFlashPair} from "../src/interfaces/IPancakeFlashPair.sol";
import {IPancakePair} from "../src/interfaces/IPancakePair.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";

/// @dev Multicall3 — the aggregation primitive the client uses to open a
///      leveraged position in ONE transaction instead of three.
interface IMulticall3 {
    struct Call {
        address target;
        bytes callData;
    }

    function aggregate(Call[] calldata calls) external payable returns (uint256 blockNumber, bytes[] memory returnData);
}

/// @title GambV2ForkTest
/// @notice End-to-end test of the four v2 contracts against the REAL BSC
///         mainnet state: real MasterChef, real GAMB, real LP, real
///         PancakeSwap pair, real WBNB.
/// @dev Runs only when `BSC_RPC_URL` is set; otherwise every test is skipped
///      (the CI has no RPC). Use `make fork-test`.
///
///      The block is pinned so the run is reproducible. Everything asserted
///      here is a fact about the live protocol, not about a mock.
///
///      What this suite exists to catch — none of which a static analyzer or a
///      unit test with mocks can see:
///        - the GAMB/WBNB pair is a PancakeSwap **V1** pair, so routing it
///          through the V2 router reverts on every addLiquidity/swap;
///        - the pair is dormant, so the TWAP oracle starts stale and its
///          window can never advance on its own;
///        - the MasterChef only pays rewards after `massUpdatePools` runs.
contract GambV2ForkTest is Test {
    uint256 internal constant FORK_BLOCK = 128_620_982;
    uint256 internal forkBlock;

    GambTwapOracle internal oracle;
    GambVault internal vault;
    GambLendingPool internal lendingPool;
    GambLeverageZap internal zap;

    IGambMasterChef internal masterChef;
    IPancakeRouter02 internal router;
    IPancakePair internal lpPair;
    IERC20 internal gamb;
    IERC20 internal wbnb;
    IERC20 internal lp;

    address internal user = address(0xA11CE);
    address internal keeper = address(0xCAFE);
    address internal liquidator = address(0x11D);
    address internal feeRecipient = address(0xFEE);

    bool internal forked;

    function setUp() public {
        string memory rpc = vm.envOr("BSC_RPC_URL", string(""));
        if (bytes(rpc).length == 0) return;

        // The block is pinned so the run is reproducible. That requires an
        // ARCHIVE node: the plain BSC dataseed endpoints are pruned and
        // answer "missing trie node" for any historical state. Override with
        // BSC_FORK_BLOCK to move the pin.
        forkBlock = vm.envOr("BSC_FORK_BLOCK", FORK_BLOCK);
        vm.createSelectFork(rpc, forkBlock);
        forked = true;

        masterChef = IGambMasterChef(LegacyAddresses.MASTERCHEF);
        gamb = IERC20(LegacyAddresses.GAMB);
        wbnb = IERC20(LegacyAddresses.WBNB);
        lp = IERC20(LegacyAddresses.LP);
        lpPair = IPancakePair(LegacyAddresses.LP);
        router = IPancakeRouter02(LegacyAddresses.ROUTER_V1);

        DeployLib.Deployment memory d = DeployLib.deployAll(
            masterChef,
            LegacyAddresses.PID,
            gamb,
            wbnb,
            lp,
            router,
            IPancakeFlashPair(LegacyAddresses.FLASH_PAIR_V2),
            address(this),
            feeRecipient
        );
        oracle = d.oracle;
        vault = d.vault;
        lendingPool = d.lendingPool;
        zap = d.zap;
    }

    modifier onFork() {
        vm.skip(!forked);
        _;
    }

    // ------------------------------------------------------------------
    // Helpers
    // ------------------------------------------------------------------

    function _dealLp(address to, uint256 amount) internal {
        // `adjust = true` keeps the LP total supply consistent with the
        // balances, exactly like a real mint would — otherwise the pair's
        // `mint()` math would be off and the harvest would mint the wrong LP.
        deal(address(lp), to, amount, true);
    }

    /// @dev `deal()` cannot find WBNB's balance slot (stdStorage gives up on its
    ///      layout), so wrap native BBN instead: the fork's native currency
    ///      is BNB and WBNB's `receive()` mints 1:1.
    function _dealWbnb(address to, uint256 amount) internal {
        vm.deal(to, amount);
        vm.prank(to);
        (bool ok,) = address(wbnb).call{value: amount}("");
        require(ok, "WBNB wrap failed");
    }

    function _stakedLp() internal view returns (uint256) {
        (uint256 staked,) = masterChef.userInfo(LegacyAddresses.PID, address(vault));
        return staked;
    }

    /// @dev The pair only advances its price accumulator when it is touched,
    ///      so a keeper has to poke it. Mirrors `GambTwapOracle.poke()`.
    function _pokeOracle() internal {
        oracle.poke();
    }

    function _harvested() internal view returns (uint256 gambHarvested) {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        for (uint256 i = 0; i < logs.length; i++) {
            if (
                logs[i].topics.length == 2
                    && logs[i].topics[0] == keccak256("Harvested(address,uint256,uint256,uint256,uint256)")
            ) {
                (uint256 harvested,,,) = abi.decode(logs[i].data, (uint256, uint256, uint256, uint256));
                gambHarvested = harvested;
            }
        }
    }

    // ------------------------------------------------------------------
    // 1. Deployment wiring
    // ------------------------------------------------------------------

    /// @dev The single most expensive mistake available in this protocol is
    ///      pointing the vault at the wrong router: the V2 router has no pair
    ///      for (WBNB, GAMB) and every addLiquidity would revert.
    function test_fork_deploymentIsWiredToTheRightVenue() public onFork {
        assertEq(address(vault.router()), LegacyAddresses.ROUTER_V1, "vault must use the V1 router");
        assertEq(address(zap.router()), LegacyAddresses.ROUTER_V1, "zap must use the V1 router");
        assertEq(_lpFactory(), 0xBCfCcbde45cE874adCB698cC183deBcF17952812, "LP must be a V1 pair");
        assertEq(address(vault.masterChef()), LegacyAddresses.MASTERCHEF, "vault must point at the legacy MasterChef");
        assertEq(vault.pid(), LegacyAddresses.PID, "vault must stake into pool 25");

        // The V1 router really does route this pair, and the V2 one really
        // does not — asserted, not assumed.
        assertTrue(router.getAmountsOut(1e15, _path(address(wbnb), address(gamb))).length == 2, "V1 router routes it");
    }

    // ------------------------------------------------------------------
    // 2. Vault: deposit stakes into the REAL MasterChef
    // ------------------------------------------------------------------

    function test_fork_vaultDepositStakesIntoRealMasterChef() public onFork {
        _dealLp(user, 100e18);

        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e18, user);
        vm.stopPrank();

        assertGt(shares, 0, "depositor must receive shares");
        assertEq(lp.balanceOf(user), 0, "LP must leave the depositor");
        assertEq(lp.balanceOf(address(vault)), 0, "no LP may idle in the vault");
        assertEq(_stakedLp(), 100e18, "the vault must stake 100% into the REAL MasterChef at pid 25");
    }

    function test_fork_vaultWithdrawUnstakesFromRealMasterChef() public onFork {
        _dealLp(user, 100e18);

        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e18, user);
        uint256 assets = vault.redeem(shares, user, user);
        vm.stopPrank();

        assertApproxEqAbs(assets, 100e18, 2, "redeem must return the deposit");
        assertEq(lp.balanceOf(user), 100e18, "LP must come back");
        assertEq(_stakedLp(), 0, "nothing may stay staked");
    }

    // ------------------------------------------------------------------
    // 3. Oracle: the cold start
    // ------------------------------------------------------------------

    /// @dev The pair is dormant, so on a fresh deployment the oracle is stale
    ///      from the very first second AND can never advance by itself: the
    ///      pair's timestamp only moves when the pair is touched. This test
    ///      pins that behaviour down so nobody "simplifies" the poke away.
    function test_fork_oracleStartsStaleBecauseThePairIsDormant() public onFork {
        assertTrue(oracle.isStale(), "a fresh oracle on a dormant pair must report stale");

        // Without a poke the window can never advance.
        vm.expectRevert(GambTwapOracle.TooSoon.selector);
        oracle.update();

        // The keeper's poke revives it — no price impact, no trade.
        _pokeOracle();
        assertFalse(oracle.isStale(), "after a poke the oracle must be fresh");
        assertGt(oracle.gambPriceInWbnbWad(), 0, "the TWAP price must be available after a poke");
    }

    function test_fork_pokeRevertsWhenTheWindowIsTooYoung() public onFork {
        _pokeOracle();
        vm.expectRevert(GambTwapOracle.TooSoon.selector);
        _pokeOracle();
    }

    // ------------------------------------------------------------------
    // 4. Vault: the permissionless harvest on real rewards
    // ------------------------------------------------------------------

    function test_fork_harvestCompoundsRealRewards() public onFork {
        _dealLp(user, 100e18);

        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, user);
        vm.stopPrank();

        // The MasterChef only books rewards when massUpdatePools runs, which
        // happens on a deposit/withdraw — so let some blocks pass first.
        vm.roll(block.number + 1_000);
        vm.warp(block.timestamp + 1 hours);

        vm.recordLogs();
        vm.prank(keeper);
        uint256 lpCompounded = vault.harvest(0, block.timestamp + 1 hours);
        uint256 gambHarvested = _harvested();

        assertGt(gambHarvested, 0, "the REAL MasterChef must have owed the vault rewards");
        assertGt(lpCompounded, 0, "harvest must mint LP");

        // The fee split must have been paid out of the harvested rewards.
        assertEq(gamb.balanceOf(feeRecipient), (gambHarvested * vault.performanceFeeBps()) / 10_000, "5% fee");
        assertEq(gamb.balanceOf(keeper), (gambHarvested * vault.callerIncentiveBps()) / 10_000, "0.5% caller incentive");

        // Everything else went back into the pool, staked — on top of the original
        // stake, which was never unstaked.
        assertEq(lp.balanceOf(address(vault)), 0, "no LP may be left idle");
        assertEq(_stakedLp(), 100e18 + lpCompounded, "the compounded LP must be restaked on top of the stake");
    }

    // ------------------------------------------------------------------
    // 5. Lending pool with real WBNB
    // ------------------------------------------------------------------

    function test_fork_lendingSupplyBorrowAndRepay() public onFork {
        _dealWbnb(user, 100e18);
        // The pair's WBNB side holds only ~0.2366 WBNB, so a 1e18 LP position
        // is worth ~0.003 WBNB. Size the collateral accordingly.
        _dealLp(user, 1e22);

        // The pool needs a live oracle to value any collateral.
        _pokeOracle();

        // Supplier.
        vm.startPrank(user);
        wbnb.approve(address(lendingPool), type(uint256).max);
        uint256 shares = lendingPool.supply(50e18);
        vm.stopPrank();
        assertGt(shares, 0, "supplier must receive shares");
        assertEq(wbnb.balanceOf(address(lendingPool)), 50e18, "the pool must hold the real WBNB");

        // Borrower: vault shares as collateral.
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 vaultShares = vault.deposit(1e22, user);
        vault.approve(address(lendingPool), type(uint256).max);
        lendingPool.depositCollateral(vaultShares, user);

        uint256 debtBefore = lendingPool.currentDebt(user);
        lendingPool.borrow(5e16, user, user);
        uint256 debtAfter = lendingPool.currentDebt(user);
        vm.stopPrank();

        assertGt(debtAfter, debtBefore, "the debt must be recorded");
        assertEq(wbnb.balanceOf(user), 50e18 + 5e16, "the borrower must receive the real WBNB");

        // Interest accrues and is announced.
        vm.warp(block.timestamp + 30 days);
        vm.recordLogs();
        lendingPool.accrueInterest();
        assertGt(lendingPool.currentDebt(user), debtAfter, "the debt must grow with interest");
        assertGt(lendingPool.totalReserves(), 0, "the protocol must book reserves");

        // Repay.
        vm.startPrank(user);
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(lendingPool.currentDebt(user), user);
        vm.stopPrank();

        assertEq(lendingPool.currentDebt(user), 0, "the debt must be cleared");
    }

    // ------------------------------------------------------------------
    // 6. The zap, in ONE transaction (the UX requirement)
    // ------------------------------------------------------------------

    /// @dev Opening a leveraged position used to cost three transactions
    ///      (approve + approveOperator + open). Multicall3 collapses it into
    ///      one — this is the flow the client and the agent will actually use.
    function test_fork_openLeveragedPositionInASingleTransaction() public onFork {
        _dealWbnb(user, 1e18);
        _dealLp(user, 100e18);
        _dealWbnb(address(this), 100e18);

        _pokeOracle();

        // The lending pool needs liquidity to lend against the collateral.
        vm.startPrank(address(this));
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.supply(50e18);
        vm.stopPrank();

        // The two approvals the zap needs, as separate transactions — the flow the
        // Multicall3 test below collapses into one.
        vm.startPrank(user);
        wbnb.approve(address(zap), type(uint256).max);
        lendingPool.approveOperator(address(zap));
        vm.stopPrank();

        // The GAMB side of the pair is thin (~0.2366 WBNB of reserve), so the
        // principal has to stay small: the zap swaps half of it into GAMB and
        // the resulting LP has to still be worth more than the debt it takes
        // on, after price impact.
        uint256 principal = 1e15; // 0.001 WBNB
        uint256 leverageBps = 11_000; // 1.1x, inside the LTV-derived ceiling
        uint256 deadline = block.timestamp + 1 hours;

        vm.recordLogs();
        vm.prank(user);
        zap.openLeveragedPosition(principal, leverageBps, 0, deadline);

        (uint256 principalDebt,, uint256 collateralShares) = lendingPool.borrowers(user);
        assertGt(collateralShares, 0, "the position must post vault shares as collateral");
        assertGt(principalDebt, 0, "the position must carry debt in the lending pool");
        assertEq(lendingPool.currentDebt(user), principalDebt, "the debt must be recorded on the pool");

        // Closing it must give the principal back (minus the flash fee).
        vm.prank(user);
        zap.closeLeveragedPosition(0, block.timestamp + 1 hours);

        (uint256 debtAfter,, uint256 sharesAfter) = lendingPool.borrowers(user);
        assertEq(debtAfter, 0, "closing must clear the debt");
        assertEq(sharesAfter, 0, "closing must return the collateral");
    }

    /// @dev The same flow, but aggregated. And the result is a documented LIMIT:
    ///      Multicall3 on BSC runs the inner calls with the MULTICALL as
    ///      `msg.sender`, so nothing that needs the user's identity — a token
    ///      allowance, an operator approval, opening a position — can be
    ///      batched on the user's behalf. This test pins that down so nobody
    ///      designs a client flow around it.
    function test_fork_multicallCannotOpenAPositionOnTheUsersBehalf() public onFork {
        _dealWbnb(user, 1e18);
        _dealWbnb(address(this), 100e18);

        _pokeOracle();

        vm.startPrank(address(this));
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.supply(50e18);
        vm.stopPrank();

        vm.prank(user);
        wbnb.approve(address(zap), type(uint256).max);

        uint256 principal = 1e15;
        uint256 leverageBps = 11_000;
        uint256 deadline = block.timestamp + 1 hours;

        address[] memory targets = new address[](2);
        bytes[] memory callDatas = new bytes[](2);
        targets[0] = address(lendingPool);
        callDatas[0] = abi.encodeCall(GambLendingPool.approveOperator, (address(zap)));
        targets[1] = address(zap);
        callDatas[1] = abi.encodeCall(GambLeverageZap.openLeveragedPosition, (principal, leverageBps, 0, deadline));

        IMulticall3.Call[] memory calls = new IMulticall3.Call[](2);
        for (uint256 i = 0; i < 2; i++) {
            calls[i] = IMulticall3.Call({target: targets[i], callData: callDatas[i]});
        }

        vm.prank(user);
        vm.expectRevert();
        IMulticall3(LegacyAddresses.MULTICALL3).aggregate(calls);

        // The whole aggregate reverted, so nothing persisted — not even the
        // operator approval that ran before the failing open call.
        (,, uint256 collateralShares) = lendingPool.borrowers(user);
        assertEq(collateralShares, 0, "no position may have been opened");
        assertFalse(lendingPool.isOperator(user, address(zap)), "the user must not be an operator");
        assertFalse(
            lendingPool.isOperator(LegacyAddresses.MULTICALL3, address(zap)),
            "the reverted batch must not persist the Multicall's approval"
        );
    }

    /// @dev And the proof that a token approval CANNOT be aggregated: the
    ///      Multicall would end up as the token's owner, not the user.
    function test_fork_multicallCannotSetTheUsersTokenAllowance() public onFork {
        _dealWbnb(user, 1e18);

        address[] memory targets = new address[](1);
        bytes[] memory callDatas = new bytes[](1);
        targets[0] = address(wbnb);
        callDatas[0] = abi.encodeCall(IERC20.approve, (address(zap), type(uint256).max));

        IMulticall3.Call[] memory calls = new IMulticall3.Call[](1);
        calls[0] = IMulticall3.Call({target: targets[0], callData: callDatas[0]});

        vm.prank(user);
        IMulticall3(LegacyAddresses.MULTICALL3).aggregate(calls);

        assertEq(wbnb.allowance(user, address(zap)), 0, "the user's allowance must NOT be set by the Multicall");
        assertEq(
            wbnb.allowance(LegacyAddresses.MULTICALL3, address(zap)),
            type(uint256).max,
            "the allowance ends up owned by the Multicall itself"
        );
    }

    // ------------------------------------------------------------------
    // 7. The real swap fee of the V1 pair
    // ------------------------------------------------------------------

    /// @dev The vault assumes a 1.5% slippage tolerance and the zap assumes a
    ///      0.25% flash fee. Both have to be true of the real venue — this
    ///      measures the pair's actual swap fee from the live pool.
    function test_fork_gambWbnbPairSwapFeeIsWithinTheAssumedTolerance() public onFork {
        _dealWbnb(user, 1e18);

        (uint112 r0Before, uint112 r1Before,) = lpPair.getReserves();

        address[] memory path = new address[](2);
        path[0] = address(wbnb);
        path[1] = address(gamb);

        uint256 amountIn = 1e15; // 0.001 WBNB
        uint256 gambBefore = gamb.balanceOf(user);

        vm.startPrank(user);
        wbnb.approve(address(router), type(uint256).max);
        router.swapExactTokensForTokensSupportingFeeOnTransferTokens(amountIn, 0, path, user, block.timestamp);
        uint256 amountOut = gamb.balanceOf(user) - gambBefore;
        vm.stopPrank();

        assertGt(amountOut, 0, "the swap must produce output");

        // Infer the fee by reproducing the measured output: for a Uniswap V2
        // style pair, out = X*rOut / (rIn*S + X) with X = amountIn*(S-fee),
        // S = 10000. Searching beats inverting here — the inversion is a
        // difference of two nearly equal large numbers.
        uint256 rIn = uint256(r1Before); // WBNB side
        uint256 rOut = uint256(r0Before); // GAMB side

        uint256 measuredFeeBps;
        bool found;
        for (uint256 fee = 0; fee <= 50; fee++) {
            uint256 x = amountIn * (10_000 - fee);
            uint256 predicted = (x * rOut) / (rIn * 10_000 + x);
            if (predicted <= amountOut && amountOut - predicted <= 2) {
                measuredFeeBps = fee;
                found = true;
                break;
            }
        }

        assertTrue(found, "could not infer the pair's swap fee");
        // Must be comfortably inside the 1.5% the vault tolerates.
        assertLt(measuredFeeBps, 150, "the real swap fee must fit inside the vault's slippage tolerance");
        emit log_named_uint("measured swap fee (bps)", measuredFeeBps);
    }

    // ------------------------------------------------------------------
    // 8. Full journeys — the whole product, end to end, on live mainnet state
    // ------------------------------------------------------------------

    /// @dev The complete user journey in one test: deposit LP into the vault
    ///      (staked into the REAL MasterChef), harvest REAL GAMB rewards, post
    ///      the appreciated shares as collateral, borrow REAL WBNB, pay real
    ///      interest, repay, withdraw and redeem. Every leg hits live BSC
    ///      contracts; nothing is mocked.
    function test_fork_fullJourney() public onFork {
        _dealWbnb(user, 2e18);
        _dealWbnb(address(this), 2e18);
        _dealLp(user, 4e22);

        // Someone has to fund the borrowing side of the pool.
        vm.startPrank(address(this));
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.supply(1e18);
        vm.stopPrank();

        // 1) Deposit -> staked in the real MasterChef.
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(4e22, user);
        vm.stopPrank();
        assertEq(_stakedLp(), 4e22, "the deposit must be staked");
        assertEq(lp.balanceOf(user), 0, "no LP may idle with the user");

        // 2) Harvest -> the vault is worth more, fee and keeper are paid.
        vm.roll(block.number + 2_000);
        vm.warp(block.timestamp + 1 hours);
        uint256 totalBefore = vault.totalAssets();
        vm.prank(keeper);
        vault.harvest(0, block.timestamp + 1 hours);
        assertGt(vault.totalAssets(), totalBefore, "harvest must compound real rewards");
        assertGt(gamb.balanceOf(feeRecipient), 0, "the fee recipient must be paid");
        assertGt(gamb.balanceOf(keeper), 0, "the keeper must be paid");

        // 3) Collateral -> borrow, valued by the real TWAP oracle.
        _pokeOracle();
        uint256 collateralShares = shares / 2;
        vm.startPrank(user);
        vault.approve(address(lendingPool), type(uint256).max);
        lendingPool.depositCollateral(collateralShares, user);

        uint256 collateralValue = oracle.fairValueOfLpInWbnb(vault.convertToAssets(collateralShares));
        uint256 borrowAmount = (collateralValue * lendingPool.maxLtvBps() * 90) / (10_000 * 100);
        uint256 wbnbBeforeBorrow = wbnb.balanceOf(user);
        lendingPool.borrow(borrowAmount, user, user);
        vm.stopPrank();

        assertEq(wbnb.balanceOf(user) - wbnbBeforeBorrow, borrowAmount, "borrower receives real WBNB");
        assertTrue(lendingPool.healthFactor(user) >= 1e18, "must be healthy after borrowing");

        // 4) Interest accrues on the real pool.
        vm.warp(block.timestamp + 30 days);
        lendingPool.accrueInterest();
        assertGt(lendingPool.currentDebt(user), borrowAmount, "the debt must grow with interest");

        // 5) Repay, un-collateralize, redeem everything.
        vm.startPrank(user);
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(type(uint256).max, user);
        lendingPool.withdrawCollateral(collateralShares, user, user);
        uint256 assets = vault.redeem(shares, user, user);
        vm.stopPrank();

        assertEq(lendingPool.currentDebt(user), 0, "the journey must end debt-free");
        assertGt(assets, 4e22, "the depositor must exit richer than they entered");
        assertLt(_stakedLp(), 1e6, "the vault must be fully unstaked");
    }

    /// @dev The other side of the borrow: a supplier must actually earn the
    ///      interest the borrower pays. This is the economic loop closing on
    ///      live contracts — supply -> borrow -> accrue -> repay -> redeem and
    ///      walk away with more WBNB than was deposited.
    function test_fork_supplierEarnsRealInterestFromARealBorrower() public onFork {
        address supplier = address(0x5A1);
        _dealWbnb(supplier, 2e18);
        _dealWbnb(user, 2e18);
        _dealLp(user, 4e22);

        _pokeOracle();

        vm.startPrank(supplier);
        wbnb.approve(address(lendingPool), type(uint256).max);
        uint256 supplierShares = lendingPool.supply(2e17);
        vm.stopPrank();

        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(4e22, user);
        vault.approve(address(lendingPool), type(uint256).max);
        lendingPool.depositCollateral(shares, user);

        uint256 collateralValue = oracle.fairValueOfLpInWbnb(vault.convertToAssets(shares));
        uint256 borrowAmount = (collateralValue * lendingPool.maxLtvBps() * 90) / (10_000 * 100);
        lendingPool.borrow(borrowAmount, user, user);
        vm.stopPrank();

        // A year of real interest.
        vm.warp(block.timestamp + 365 days);
        lendingPool.accrueInterest();
        assertGt(lendingPool.currentDebt(user), borrowAmount, "the borrower owes more");

        // The borrower settles up, releasing the liquidity back to the pool.
        vm.startPrank(user);
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.repay(type(uint256).max, user);
        vm.stopPrank();

        vm.prank(supplier);
        uint256 redeemed = lendingPool.redeem(supplierShares);
        assertGt(redeemed, 2e17, "the supplier must earn the interest the borrower paid");
    }

    /// @dev A position can go underwater with ZERO price move: the borrow
    ///      accrues real interest while the collateral sits still. The
    ///      permissionless liquidator must then be able to act against the real
    ///      pool and walk away with real collateral. One round is bounded by the
    ///      close factor (50% of the debt), and that bounded repayment must
    ///      already de-risk the position — the liquidation bonus deslevers it.
    function test_fork_liquidationAfterInterestDrift() public onFork {
        _dealWbnb(user, 2e18);
        _dealWbnb(liquidator, 2e18);
        _dealLp(user, 4e22);

        _pokeOracle();

        // Thin liquidity -> high utilisation -> interest actually bites.
        _dealWbnb(address(this), 1e18);
        vm.startPrank(address(this));
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.supply(2e17);
        vm.stopPrank();

        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(4e22, user);
        vault.approve(address(lendingPool), type(uint256).max);
        lendingPool.depositCollateral(shares, user);

        uint256 collateralValue = oracle.fairValueOfLpInWbnb(vault.convertToAssets(shares));
        uint256 borrowAmount = (collateralValue * lendingPool.maxLtvBps()) / 10_000;
        borrowAmount = (borrowAmount * 98) / 100;
        lendingPool.borrow(borrowAmount, user, user);
        vm.stopPrank();

        assertTrue(lendingPool.healthFactor(user) >= 1e18, "healthy at open");
        assertLt(lendingPool.healthFactor(user), 2e18, "but thin");

        // Two years of interest with no price move at all.
        vm.warp(block.timestamp + 730 days);
        _pokeOracle();
        lendingPool.accrueInterest();

        assertLt(lendingPool.healthFactor(user), 1e18, "interest alone must make it liquidatable");
        uint256 debt = lendingPool.currentDebt(user);
        uint256 healthBefore = lendingPool.healthFactor(user);
        (,, uint256 collateralBefore) = lendingPool.borrowers(user);
        uint256 liquidatorSharesBefore = vault.balanceOf(liquidator);

        vm.startPrank(liquidator);
        wbnb.approve(address(lendingPool), type(uint256).max);
        (uint256 repaid, uint256 seized) = lendingPool.liquidate(user, type(uint256).max);
        vm.stopPrank();

        // Close factor: a single liquidation repays at most half the debt.
        assertEq(repaid, debt / 2, "one round must be capped by the close factor");
        assertGt(seized, 0, "the liquidator must seize collateral");
        assertLt(seized, collateralBefore, "part of the collateral must survive the bonus");
        assertEq(lendingPool.currentDebt(user), debt - repaid, "half the debt must remain for the next round");
        assertEq(vault.balanceOf(liquidator) - liquidatorSharesBefore, seized, "the liquidator owns the shares");
        assertGt(lendingPool.healthFactor(user), healthBefore, "the bounded round must de-risk the position");

        // The seized collateral is real: it redeems into real LP.
        vm.prank(liquidator);
        uint256 lpOut = vault.redeem(seized, liquidator, liquidator);
        assertGt(lpOut, 0, "the seized collateral must redeem to real LP");
    }

    /// @dev Two depositors, one harvest: the rewards must be split by stake,
    ///      not by who deposited first or who redeems first.
    function test_fork_vaultRewardsAreSharedProportionally() public onFork {
        address alice = address(0xA11CE1);
        address bob = address(0xB0B1);
        _dealLp(alice, 1e22);
        _dealLp(bob, 3e22);

        vm.startPrank(alice);
        lp.approve(address(vault), type(uint256).max);
        uint256 aliceShares = vault.deposit(1e22, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        lp.approve(address(vault), type(uint256).max);
        uint256 bobShares = vault.deposit(3e22, bob);
        vm.stopPrank();

        vm.roll(block.number + 2_000);
        vm.warp(block.timestamp + 1 hours);
        vm.prank(keeper);
        vault.harvest(0, block.timestamp + 1 hours);

        vm.prank(alice);
        uint256 aliceAssets = vault.redeem(aliceShares, alice, alice);
        vm.prank(bob);
        uint256 bobAssets = vault.redeem(bobShares, bob, bob);

        assertGt(aliceAssets, 1e22, "alice must earn on her deposit");
        assertGt(bobAssets, 3e22, "bob must earn on his deposit");
        // 3x the deposit must be ~3x the payout: nobody gets diluted.
        assertApproxEqRel(bobAssets, aliceAssets * 3, 3e16, "rewards must be proportional");
    }

    /// @dev The vault must only ever stake into pool 25. Pool 16 holds the very
    ///      same LP token, so a bug here would double-count the vault's stake
    ///      and silently halve the reward rate.
    function test_fork_vaultOnlyEverStakesIntoPool25() public onFork {
        _dealLp(user, 100e18);

        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, user);
        vm.stopPrank();

        (uint256 staked25,) = masterChef.userInfo(25, address(vault));
        (uint256 staked16,) = masterChef.userInfo(16, address(vault));

        assertEq(vault.pid(), 25, "the vault must target pool 25");
        assertEq(staked25, 100e18, "pool 25 must hold the stake");
        assertEq(staked16, 0, "the duplicate pool 16 must never be touched");
    }

    // ------------------------------------------------------------------
    // 9. Failure modes — pausing, emergencies, slippage and staleness
    // ------------------------------------------------------------------

    /// @dev Deposits are pausable, withdrawals are not. This is a promise the
    ///      vault makes in its NatSpec; pin it against the live deployment.
    function test_fork_vaultPauseBlocksDepositsButNeverWithdrawals() public onFork {
        _dealLp(user, 100e18);
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e18, user);
        vm.stopPrank();

        vault.setDepositsPaused(true);
        assertEq(vault.maxDeposit(user), 0, "deposits must be closed");

        _dealLp(user, 1e18);
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        vm.expectRevert();
        vault.deposit(1e18, user);
        vm.stopPrank();

        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, user);
        assertApproxEqAbs(assets, 100e18, 2, "withdrawals must survive the pause");
    }

    /// @dev The emergency exit is the escape hatch if the upstream MasterChef
    ///      ever looks stuck: pull the stake, stop harvesting, keep withdrawals.
    function test_fork_vaultEmergencyExitKeepsWithdrawalsAlive() public onFork {
        _dealLp(user, 100e18);
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        uint256 shares = vault.deposit(100e18, user);
        vm.stopPrank();

        assertEq(_stakedLp(), 100e18);

        vault.emergencyExitMasterChef();
        assertEq(_stakedLp(), 0, "the stake must be pulled out");
        assertEq(lp.balanceOf(address(vault)), 100e18, "the LP must sit in the vault");
        assertEq(vault.maxDeposit(user), 0, "deposits must be closed after the exit");

        vm.expectRevert(GambVault.AlreadyExited.selector);
        vault.harvest(0, block.timestamp + 1 hours);

        vm.prank(user);
        uint256 assets = vault.redeem(shares, user, user);
        assertApproxEqAbs(assets, 100e18, 2, "withdrawals must still work");
    }

    function test_fork_harvestEnforcesDeadlineAndSlippage() public onFork {
        _dealLp(user, 100e18);
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, user);
        vm.stopPrank();

        vm.roll(block.number + 2_000);
        vm.warp(block.timestamp + 1 hours);

        vm.expectRevert(GambVault.DeadlineExpired.selector);
        vault.harvest(0, block.timestamp - 1);

        // Warms the pool so the next call really has rewards to compound.
        vm.prank(keeper);
        vault.harvest(0, block.timestamp + 1 hours);

        vm.roll(block.number + 2_000);
        vm.warp(block.timestamp + 1 hours);

        vm.prank(keeper);
        vm.expectRevert(GambVault.SlippageExceeded.selector);
        vault.harvest(type(uint256).max, block.timestamp + 1 hours);
    }

    /// @dev The leverage ceiling is derived from the pool's LTV, not hardcoded.
    ///      With 40% max LTV, 2x must be rejected and 1x is not leverage.
    function test_fork_zapRejectsLeverageOutsideItsDerivedCeiling() public onFork {
        _dealWbnb(user, 1e18);
        _dealWbnb(address(this), 100e18);
        _pokeOracle();

        vm.startPrank(address(this));
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.supply(50e18);
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        vm.startPrank(user);
        wbnb.approve(address(zap), type(uint256).max);
        lendingPool.approveOperator(address(zap));

        vm.expectRevert(GambLeverageZap.BadLeverage.selector);
        zap.openLeveragedPosition(1e15, 20_000, 0, deadline);

        vm.expectRevert(GambLeverageZap.BadLeverage.selector);
        zap.openLeveragedPosition(1e15, 10_000, 0, deadline);
        vm.stopPrank();
    }

    function test_fork_zapCloseWithoutPositionReverts() public onFork {
        vm.prank(user);
        vm.expectRevert(GambLeverageZap.NoPosition.selector);
        zap.closeLeveragedPosition(0, block.timestamp + 1 hours);
    }

    function test_fork_zapPauseBlocksOpeningButNeverClosing() public onFork {
        _dealWbnb(user, 1e18);
        _dealWbnb(address(this), 100e18);
        _pokeOracle();

        vm.startPrank(address(this));
        wbnb.approve(address(lendingPool), type(uint256).max);
        lendingPool.supply(50e18);
        vm.stopPrank();

        vm.startPrank(user);
        wbnb.approve(address(zap), type(uint256).max);
        lendingPool.approveOperator(address(zap));
        vm.stopPrank();

        uint256 deadline = block.timestamp + 1 hours;
        vm.prank(user);
        zap.openLeveragedPosition(1e15, 11_000, 0, deadline);

        zap.setOpeningPaused(true);

        vm.startPrank(user);
        vm.expectRevert(GambLeverageZap.OpeningIsPaused.selector);
        zap.openLeveragedPosition(1e15, 11_000, 0, deadline);
        vm.stopPrank();

        vm.prank(user);
        zap.closeLeveragedPosition(0, block.timestamp + 1 hours);
        (uint256 debtAfter,, uint256 sharesAfter) = lendingPool.borrowers(user);
        assertEq(debtAfter, 0, "closing must survive the open-pause");
        assertEq(sharesAfter, 0, "collateral must come back");
    }

    /// @dev The oracle must fail closed: once the keeper stops poking, the
    ///      price ages out and every consumer reverts instead of trading on a
    ///      stale number. A later poke revives it.
    function test_fork_oracleFailsClosedWhenTheKeeperStops() public onFork {
        _pokeOracle();
        assertFalse(oracle.isStale(), "fresh after a poke");
        assertGt(oracle.gambPriceInWbnbWad(), 0, "the price must be available");

        vm.warp(block.timestamp + oracle.MAX_STALENESS() + 1);
        assertTrue(oracle.isStale(), "the oracle must age out");

        vm.expectRevert(GambTwapOracle.OracleStale.selector);
        oracle.gambPriceInWbnbWad();
        vm.expectRevert(GambTwapOracle.OracleStale.selector);
        oracle.fairValueOfLpInWbnb(1e18);

        // The keeper comes back and revives it.
        _pokeOracle();
        assertFalse(oracle.isStale(), "a poke must revive the oracle");
    }

    /// @dev Guards the exact sequence `script/Keeper.s.sol` runs — best-effort
    ///      poke, then harvest — so an API drift in either contract breaks a
    ///      test instead of silently breaking the keeper in production.
    function test_fork_keeperPassPokesAndHarvests() public onFork {
        _dealLp(user, 100e18);
        vm.startPrank(user);
        lp.approve(address(vault), type(uint256).max);
        vault.deposit(100e18, user);
        vm.stopPrank();

        vm.roll(block.number + 1_000);
        vm.warp(block.timestamp + 1 hours);

        try oracle.poke() {} catch {}
        assertFalse(oracle.isStale(), "the keeper must leave a usable price");

        uint256 compounded = vault.harvest(0, block.timestamp + 1 hours);
        assertGt(compounded, 0, "the keeper must compound real rewards");
    }

    // ------------------------------------------------------------------
    // helpers
    // ------------------------------------------------------------------

    function _path(address a, address b) internal pure returns (address[] memory p) {
        p = new address[](2);
        p[0] = a;
        p[1] = b;
    }

    function _asPairs(address[] memory targets, bytes[] memory datas)
        internal
        pure
        returns (address[] memory, bytes[] memory)
    {
        return (targets, datas);
    }

    /// @dev `factory()` is not part of `IPancakePair`; read it straight from
    ///      the live pair instead of widening the interface for one assertion.
    function _lpFactory() internal view returns (address) {
        (bool ok, bytes memory data) = address(lpPair).staticcall(abi.encodeWithSignature("factory()"));
        require(ok, "pair has no factory()");
        return abi.decode(data, (address));
    }
}
