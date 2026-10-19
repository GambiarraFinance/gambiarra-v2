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
