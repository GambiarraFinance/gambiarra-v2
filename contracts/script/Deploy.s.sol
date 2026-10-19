// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {console2} from "forge-std/console2.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {DeployLib, LegacyAddresses} from "./DeployLib.sol";
import {IGambMasterChef} from "../src/interfaces/IGambMasterChef.sol";
import {IPancakeFlashPair} from "../src/interfaces/IPancakeFlashPair.sol";
import {IPancakeRouter02} from "../src/interfaces/IPancakeRouter02.sol";

/// @title Deploy
/// @notice Deploys the four Gambiarra v2 contracts against the legacy
///         Gambiarra MasterChef on BSC.
/// @dev On a fork:
///        forge script script/Deploy.s.sol:Deploy --rpc-url $BSC_RPC_URL \
///          --fork-block-number 128620982 --broadcast --private-key $PK
///      On mainnet, drop both --fork flags.
contract Deploy is Script {
    function run() external returns (DeployLib.Deployment memory d) {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerKey);

        // The owner of the protocol is deliberately allowed to differ from the
        // deployer — in production it should be a multisig, never an EOA.
        address owner = vm.envOr("PROTOCOL_OWNER", deployer);
        address feeRecipient = vm.envOr("FEE_RECIPIENT", owner);

        vm.startBroadcast(deployerKey);

        d = DeployLib.deployAll(
            IGambMasterChef(LegacyAddresses.MASTERCHEF),
            LegacyAddresses.PID,
            IERC20(LegacyAddresses.GAMB),
            IERC20(LegacyAddresses.WBNB),
            IERC20(LegacyAddresses.LP),
            IPancakeRouter02(LegacyAddresses.ROUTER_V1),
            IPancakeFlashPair(LegacyAddresses.FLASH_PAIR_V2),
            owner,
            feeRecipient
        );

        vm.stopBroadcast();

        console2.log("GambTwapOracle  :", address(d.oracle));
        console2.log("GambVault      :", address(d.vault));
        console2.log("GambLendingPool:", address(d.lendingPool));
        console2.log("GambLeverageZap:", address(d.zap));
        console2.log("owner          :", owner);
        console2.log("feeRecipient   :", feeRecipient);
        console2.log("pid            :", LegacyAddresses.PID);
        console2.log("router (V1)    :", LegacyAddresses.ROUTER_V1);
        console2.log("flashPair (V2) :", LegacyAddresses.FLASH_PAIR_V2);
    }
}
