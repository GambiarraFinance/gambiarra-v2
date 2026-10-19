// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";

import {GambTwapOracle} from "../src/GambTwapOracle.sol";
import {GambVault} from "../src/GambVault.sol";

/// @title Keeper
/// @notice One-shot, permissionless keeper pass: refresh the GAMB/WBNB TWAP
///         window and compound the vault's pending rewards.
/// @dev Neither action needs a privileged key — both are permissionless by
///      design, so any funded EOA can run this. It is meant to be driven by a
///      scheduler (cron, systemd timer, a bot):
///
///        ORACLE_ADDRESS=0x… VAULT_ADDRESS=0x… KEEPER_PRIVATE_KEY=0x… \
///        forge script script/Keeper.s.sol:Keeper \
///          --rpc-url "$BSC_RPC_URL" --broadcast
///
///      Both legs are best-effort and independent: a `TooSoon` from `poke()`
///      (the pair was touched less than MIN_PERIOD ago) or an empty vault is a
///      normal no-op, not an incident, so neither aborts the other.
///
///      Why this exists: the GAMB/WBNB pair is dormant, so its price
///      accumulator only moves when someone touches it. Without a periodic
///      `poke()`, the TWAP ages past `MAX_STALENESS` (2h) and the lending pool
///      refuses every collateral valuation — every borrow stops. `poke()` is
///      itself free of price impact: it calls the pair's `sync()`, never a
///      trade. See AGENTS.md, invariant 12.
contract Keeper is Script {
    function run() external {
        address oracleAddress = vm.envAddress("ORACLE_ADDRESS");
        address vaultAddress = vm.envOr("VAULT_ADDRESS", address(0));
        uint256 keeperKey = vm.envUint("KEEPER_PRIVATE_KEY");

        GambTwapOracle oracle = GambTwapOracle(oracleAddress);

        vm.startBroadcast(keeperKey);

        // 1) Refresh the TWAP window. Reverts `TooSoon` if the pair was touched
        //    less than MIN_PERIOD (30 min) ago; that is expected, not a fault.
        try oracle.poke() {
            console2.log("oracle poked; TWAP price (GAMB/WBNB, wad):", oracle.priceAverageWad());
        } catch {
            console2.log("oracle not ready yet (TooSoon) - no-op this pass");
        }

        // 2) Compound the vault's pending GAMB into more LP, if one was given.
        if (vaultAddress != address(0)) {
            GambVault vault = GambVault(vaultAddress);
            if (vault.emergencyExited()) {
                console2.log("vault already emergency-exited; nothing to compound");
            } else {
                try vault.harvest(0, block.timestamp + 1 hours) returns (uint256 lpCompounded) {
                    console2.log("vault compounded LP:", lpCompounded);
                } catch {
                    console2.log("vault harvest skipped this pass");
                }
            }
        }

        vm.stopBroadcast();
    }
}
