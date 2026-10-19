// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {GambTwapOracle} from "../src/GambTwapOracle.sol";
import {MockFlashPair} from "./mocks/MockFlashPair.sol";

/// @notice Executable proof of the fair-LP-value math derived in
///         GambTwapOracle's NatSpec: for a balanced pool (equal reserves,
///         price 1:1), the fair value of the ENTIRE LP supply must equal the
///         literal sum of both reserves (there's only one way to split a
///         balanced pool's value between two equally-priced assets).
contract GambTwapOracleTest is Test {
    address constant GAMB = address(0xA11CE);
    address constant WBNB = address(0xB0B);

    MockFlashPair pair;
    GambTwapOracle oracle;

    function setUp() public {
        pair = new MockFlashPair(GAMB, WBNB); // token0 = GAMB, token1 = WBNB
        pair.setReserves(1000e18, 1000e18); // 1:1 spot price
        pair.setTotalSupply(1000e18); // pretend totalSupply == 1000 LP tokens
        oracle = new GambTwapOracle(pair, GAMB, WBNB);
    }

    function _warmUpTwap(uint32 elapsed) internal {
        pair.advance(elapsed);
        oracle.update();
    }

    function test_balancedPool_fairValueOfFullSupply_equalsReserveSum() public {
        _warmUpTwap(31 minutes); // price was 1:1 the whole time -> TWAP = 1e18

        assertEq(oracle.gambPriceInWbnbWad(), 1e18, "TWAP should read exactly 1:1");

        uint256 fullSupply = 1000e18;
        uint256 value = oracle.fairValueOfLpInWbnb(fullSupply);

        // Pool holds 1000 GAMB (worth 1000 WBNB at 1:1) + 1000 WBNB = 2000 WBNB total.
        assertEq(value, 2000e18, "fair value of full LP supply must equal total pool value");
    }

    function test_halfSupply_isHalfValue() public {
        _warmUpTwap(31 minutes);
        uint256 half = 500e18;
        assertEq(oracle.fairValueOfLpInWbnb(half), 1000e18);
    }

    function test_revertsWhenStale() public {
        // Warm up once so there's a real TWAP price on record...
        _warmUpTwap(31 minutes);
        assertFalse(oracle.isStale());

        // ...then let the (mock) pair's clock move forward without anyone
        // calling update() again. isStale() reads elapsed time via the
        // pair's own reported timestamp (exactly like production, where the
        // real Pancake pair's blockTimestampLast tracks real time), so we
        // advance the mock pair directly rather than vm.warp (which the mock
        // doesn't observe on its own).
        pair.advance(uint32(oracle.MAX_STALENESS()) + 1);

        assertTrue(oracle.isStale());
        vm.expectRevert(GambTwapOracle.OracleStale.selector);
        oracle.gambPriceInWbnbWad();
    }

    function test_revertsIfUpdatedTooSoon() public {
        pair.advance(10 minutes); // less than MIN_PERIOD (30 min)
        vm.expectRevert(GambTwapOracle.TooSoon.selector);
        oracle.update();
    }

    function test_skewedReserves_sameTwapPrice_fairValueBarelyMoves() public {
        // Simulate an attacker skewing spot reserves 4x within one block
        // (classic single-sided manipulation attempt) while the TWAP price
        // (which only moves over MIN_PERIOD-sized windows) stays at the old
        // 1:1 average. The constant-product invariant k = r0*r1 is
        // approximately preserved by any in-pool swap (minus fees), so the
        // fair-value formula should barely move even though spot reserves
        // moved drastically — this is the whole point of using sqrt(r0*r1)
        // instead of a naive reserve-times-price sum.
        _warmUpTwap(31 minutes); // lock in TWAP = 1e18 from the balanced state
        uint256 valueBefore = oracle.fairValueOfLpInWbnb(1000e18);

        // k = 1000e18 * 1000e18 preserved: new reserves 4000e18 / 250e18.
        pair.setReserves(4000e18, 250e18);
        // NOTE: we do NOT call update() here — the TWAP price is unaffected
        // by this single-block reserve skew, exactly as intended.
        uint256 valueAfter = oracle.fairValueOfLpInWbnb(1000e18);

        // sqrt(4000e18 * 250e18) == sqrt(1000e18*1000e18) == 1000e18 (k preserved exactly here),
        // so fair value should be identical.
        assertEq(valueAfter, valueBefore, "fair value should be invariant to a k-preserving reserve skew");
    }
}
