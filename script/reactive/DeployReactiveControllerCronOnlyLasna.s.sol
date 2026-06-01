// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ShieldReactiveControllerCronOnly} from "../../src/reactive/ShieldReactiveControllerCronOnly.sol";

/// @notice Deploy the cron-only ShieldReactiveController on Reactive Lasna.
///
/// Single-subscription (CRON) variant used to validate the rvm_id auth fix
/// end-to-end on real testnet without re-creating the regime-event subscription
/// (which was rejected by the system contract when re-subscribed from the same
/// deployer EOA).
///
/// Env (all required):
///  - REACTIVE_PRIVATE_KEY     broadcaster on Lasna (funded with lREACT)
///  - DESTINATION_CHAIN_ID     e.g. 84532 (Base Sepolia, where the executor lives)
///  - SHIELD_EXECUTOR          deployed ShieldReactiveExecutor address (destination)
///  - TARGET_POOL_ID           bytes32 poolId to sweep on CRON
///  - CRON_SYSTEM              CRON system-contract address (classic: 0x…fffFfF)
///  - CRON_TOPIC0              topic0 of the chosen CRON cadence
///  - CONTROLLER_FUNDING_WEI   optional; msg.value sent to controller at deploy
contract DeployReactiveControllerCronOnlyLasna is Script {
    uint256 private constant LASNA_CHAIN_ID = 5318007;

    function run() external {
        require(block.chainid == LASNA_CHAIN_ID, "wrong chain: expected Reactive Lasna 5318007");

        uint256 pk = vm.envUint("REACTIVE_PRIVATE_KEY");
        uint256 destChainId = vm.envUint("DESTINATION_CHAIN_ID");
        address executor = vm.envAddress("SHIELD_EXECUTOR");
        bytes32 targetPoolId = vm.envBytes32("TARGET_POOL_ID");
        address cronSystem = vm.envAddress("CRON_SYSTEM");
        uint256 cronTopic0 = vm.envUint("CRON_TOPIC0");
        uint256 funding = vm.envOr("CONTROLLER_FUNDING_WEI", uint256(0));
        address rvmId = vm.addr(pk);

        vm.startBroadcast(pk);
        ShieldReactiveControllerCronOnly controller = new ShieldReactiveControllerCronOnly{value: funding}(
            destChainId, executor, PoolId.wrap(targetPoolId), cronSystem, cronTopic0
        );
        vm.stopBroadcast();

        console2.log("network", "reactive-lasna");
        console2.log("controller", address(controller));
        console2.log("controllerRvmId", rvmId);
        console2.log("destinationChainId", destChainId);
        console2.log("executor", executor);
        console2.logBytes32(targetPoolId);
        console2.log("cronSystem", cronSystem);
        console2.log("fundedWei", funding);
        console2.log(
            "NEXT: on the destination chain, call executor.setController(controller, controllerRvmId) to lock the wiring."
        );
    }
}
