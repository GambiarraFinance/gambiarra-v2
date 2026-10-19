// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPancakeFlashPair} from "./interfaces/IPancakeFlashPair.sol";
import {IGambTwapOracle} from "./interfaces/IGambTwapOracle.sol";

/// @title GambTwapOracle
/// @notice Permissionless TWAP price oracle for the GAMB/WBNB PancakeSwap V2
///         pair. This is the single highest-risk component of the whole
///         leverage stack: GAMB has no independent/external price feed
///         anywhere (no Chainlink feed exists for it), so this contract's
///         own historical trading data is the ONLY source of truth we have
///         for "what is GAMB worth". The pool was also measured at tiny TVL
///         (~9 LP tokens) in this repo's on-chain audit — a thin pool is
///         cheaper to move, which is exactly why this uses a time-averaged
///         price instead of the spot reserve ratio.
/// @dev Classic Uniswap V2 TWAP accumulator pattern. Anyone (a keeper bot,
///      another agent) can call `update()`, at most once per MIN_PERIOD.
///      Consumers MUST treat a stale price as "unavailable", never fall back
///      to spot — see `gambPriceInWbnbWad`, which reverts rather than
///      returning a guess. Fail closed, not open.
contract GambTwapOracle is IGambTwapOracle {
    uint256 public constant MIN_PERIOD = 30 minutes;
    uint256 public constant MAX_STALENESS = 2 hours;
    uint256 public constant WAD = 1e18;
    uint256 private constant Q112 = 2 ** 112;

    IPancakeFlashPair public immutable pair;
    address public immutable gamb;
    address public immutable wbnb;
    bool public immutable gambIsToken0;

    uint256 public priceCumulativeLast;
    uint32 public blockTimestampLast;
    uint256 public priceAverageWad; // GAMB price in WBNB, 1e18 fixed point

    error TooSoon();
    error NoElapsedTime();
    error OracleStale();
    error PairAssetMismatch();

    /// @notice Emitted on every successful `update()`. Without this, off-chain
    ///         indexers and agents had no way to know the TWAP window moved.
    event PriceUpdated(uint256 priceAverageWad, uint32 blockTimestampLast);

    constructor(IPancakeFlashPair pair_, address gamb_, address wbnb_) {
        bool isToken0 = pair_.token0() == gamb_;
        if (!isToken0 && pair_.token1() != gamb_) revert PairAssetMismatch();
        if (isToken0 && pair_.token1() != wbnb_) revert PairAssetMismatch();
        if (!isToken0 && pair_.token0() != wbnb_) revert PairAssetMismatch();

        pair = pair_;
        gamb = gamb_;
        wbnb = wbnb_;
        gambIsToken0 = isToken0;

        priceCumulativeLast = isToken0 ? pair_.price0CumulativeLast() : pair_.price1CumulativeLast();
        (,, uint32 ts) = pair_.getReserves();
        blockTimestampLast = ts;
    }

    /// @notice Advances the TWAP window. Permissionless on purpose — this is
    ///         meant to be called by keeper bots / agents, not an admin.
    function update() external {
        uint256 priceCumulative = gambIsToken0 ? pair.price0CumulativeLast() : pair.price1CumulativeLast();
        (,, uint32 blockTimestamp) = pair.getReserves();

        unchecked {
            uint32 timeElapsed = blockTimestamp - blockTimestampLast; // intentional wraparound, same as Pancake/Uniswap itself
            if (timeElapsed < MIN_PERIOD) revert TooSoon();
            if (timeElapsed == 0) revert NoElapsedTime();

            // priceCumulative is a UQ112x112 fixed-point accumulator. Divide
            // the delta by elapsed time to get the Q112-scaled time-average,
            // then rescale from Q112 to 1e18 ("WAD") fixed point.
            // Math.mulDiv does the rescale with a 512-bit intermediate, so the
            // Q112 accumulator can never overflow the way `* 1e18` would.
            uint256 priceAverageQ112 = (priceCumulative - priceCumulativeLast) / timeElapsed;
            priceAverageWad = Math.mulDiv(priceAverageQ112, WAD, Q112);
        }

        priceCumulativeLast = priceCumulative;
        blockTimestampLast = blockTimestamp;

        emit PriceUpdated(priceAverageWad, blockTimestamp);
    }

    function isStale() public view returns (bool) {
        (,, uint32 currentTs) = pair.getReserves();
        unchecked {
            return (currentTs - blockTimestampLast) > MAX_STALENESS;
        }
    }

    /// @notice GAMB price denominated in WBNB, as a 1e18 fixed-point number
    ///         (e.g. 5e17 means 1 GAMB = 0.5 WBNB). Reverts if stale.
    function gambPriceInWbnbWad() public view returns (uint256) {
        if (isStale()) revert OracleStale();
        return priceAverageWad;
    }

    /// @notice "Fair" value of `lpAmount` GAMB/WBNB LP tokens, denominated in
    ///         WBNB (native 1e18 units). Uses the Alpha-Homora-style
    ///         geometric-mean formula — 2*sqrt(r0*p0*r1*p1)/totalSupply —
    ///         instead of naively summing reserve*price per side, because the
    ///         naive sum IS manipulable: an attacker can skew reserves inside
    ///         a single transaction such that the enlarged side, valued at a
    ///         slow-moving TWAP price, overstates the pool's true value. The
    ///         geometric mean is far less sensitive to that skew because
    ///         r0*r1 (the constant-product invariant) barely changes across a
    ///         swap net of fees, regardless of which direction it's skewed.
    ///         Reverts if the TWAP price is stale.
    function fairValueOfLpInWbnb(uint256 lpAmount) external view returns (uint256 valueInWbnb) {
        uint256 priceGambWad = gambPriceInWbnbWad(); // reverts if stale
        (uint112 r0, uint112 r1,) = pair.getReserves();
        uint256 totalSupply = pair.totalSupply();
        if (totalSupply == 0 || lpAmount == 0) return 0;

        uint256 px0 = gambIsToken0 ? priceGambWad : WAD;
        uint256 px1 = gambIsToken0 ? WAD : priceGambWad;

        uint256 sqrtK = Math.sqrt(uint256(r0) * uint256(r1));
        uint256 sqrtPx = Math.sqrt(px0 * px1);

        // totalValueWad == 2 * sqrt(r0*r1) * sqrt(p0*p1), the fair WBNB value
        // of the ENTIRE pool scaled by 1e18 (see constructor-time unit proof
        // in test/GambTwapOracle.t.sol for a worked numeric example).
        uint256 totalValueWad = 2 * sqrtK * sqrtPx;

        // Math.mulDiv does the (totalValueWad * lpAmount) step with 512-bit
        // intermediate precision, so this neither overflows nor loses
        // precision the way `(totalValueWad / totalSupply) * lpAmount` would.
        valueInWbnb = Math.mulDiv(totalValueWad, lpAmount, totalSupply) / WAD;
    }
}
