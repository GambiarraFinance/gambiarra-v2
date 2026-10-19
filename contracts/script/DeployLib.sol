// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {GambVault} from "../src/GambVault.sol";
import {GambLendingPool} from "../src/GambLendingPool.sol";
import {GambLeverageZap} from "../src/GambLeverageZap.sol";
import {GambTwapOracle} from "../src/GambTwapOracle.sol";
import {IGambMasterChef} from "../src/interfaces/IGambMasterChef.sol";
import {IGambVault} from "../src/interfaces/IGambVault.sol";
import {IGambTwapOracle} from "../src/interfaces/IGambTwapOracle.sol";
import {IPancakeFlashPair} from "../src/interfaces/IPancakeFlashPair.sol";
import {IPancakePair} from "../src/interfaces/IPancakePair.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";

/// @title LegacyAddresses
/// @notice Every address this protocol binds to on BSC mainnet, each one
///         verified on-chain with `cast`.
/// @dev THE IMPORTANT ONE: the GAMB/WBNB LP is a **PancakeSwap V1** pair, not
///      a V2 pair. Its factory is `0xBCfCcbde…` (the original PancakeSwap,
///      April 2021), confirmed by `INIT_CODE_PAIR_HASH()` returning
///      `0xd0d4c4cd0848c93cb4fd1f498d7013ee6bfb25783ea21593d5834f5d250ece66`.
///      The PancakeSwap **V2** factory `0xcA143Ce3…` returns `address(0)` for
///      the (WBNB, GAMB) pair — routing through the V2 router would revert on
///      every addLiquidity/removeLiquidity/swap against this LP.
library LegacyAddresses {
    /// @notice Legacy Gambiarra MasterChef (ownership renounced, immutable).
    address internal constant MASTERCHEF = 0x77c1618248358f92Cb144269790103e67378A550;
    /// @notice GAMB token (18 decimals).
    address internal constant GAMB = 0x18CdE546D6Ca4DB3b6E62109addE38ee7B1Dd068;
    /// @notice GAMB/WBNB LP — a PancakeSwap **V1** pair.
    address internal constant LP = 0x62DCE0C4E2df11A1bcB2a718F9F43389d91310D5;
    /// @notice Wrapped BNB.
    address internal constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /// @notice PancakeSwap **V1** Router02 — the only router that can route
    ///         the GAMB/WBNB pair, because that pair lives on the V1 factory.
    address internal constant ROUTER_V1 = 0x05fF2B0DB69458A0750badebc4f9e13aDd608C7F;

    /// @notice PancakeSwap **V2** WBNB/BUSD pair — the flash-loan source.
    /// @dev Deliberately a V2 pair even though the LP is a V1 pair: this one is
    ///      deep (6.1k WBNB) and its 0.25% flash fee is exactly what
    ///      `GambLeverageZap._flashRepayAmount()` assumes. The flash pair is
    ///      independent of the LP's venue.
    address internal constant FLASH_PAIR_V2 = 0x58F876857a02D6762E0101bb5C46A8c1ED44Dc16;

    /// @notice Multicall3 — lets a client open a leveraged position in a
    ///         single transaction instead of approve + approveOperator + open.
    address internal constant MULTICALL3 = 0xcA11bde05977b3631167028862bE2a173976CA11;

    /// @notice MasterChef pool holding the GAMB/WBNB LP. Pool 16 holds the very
    ///         same LP with allocPoint 1e29; pool 25 holds it with 3e29, so
    ///         pool 25 pays 3x the emissions.
    uint256 internal constant PID = 25;
}

/// @title DeployLib
/// @notice Single source of truth for how the four contracts are wired
///         together. Used by `Deploy.s.sol` (real deployments and forks) and
///         by the fork tests, so what is tested is exactly what ships.
library DeployLib {
    struct Deployment {
        GambTwapOracle oracle;
        GambVault vault;
        GambLendingPool lendingPool;
        GambLeverageZap zap;
    }

    function deployAll(
        IGambMasterChef masterChef,
        uint256 pid,
        IERC20 gamb,
        IERC20 wbnb,
        IERC20 lpToken,
        IPancakeRouter02 router,
        IPancakeFlashPair flashPair,
        address owner,
        address feeRecipient
    ) internal returns (Deployment memory d) {
        // Oracle first: the lending pool needs it for collateral valuation.
        d.oracle = new GambTwapOracle(IPancakePair(address(lpToken)), address(gamb), address(wbnb));

        d.vault = new GambVault(lpToken, masterChef, pid, gamb, wbnb, router, owner, feeRecipient);

        d.lendingPool =
            new GambLendingPool(wbnb, IGambVault(address(d.vault)), IGambTwapOracle(address(d.oracle)), owner);

        d.zap = new GambLeverageZap(
            wbnb, gamb, lpToken, router, IGambVault(address(d.vault)), d.lendingPool, flashPair, owner
        );
    }
}
