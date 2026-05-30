// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";

import {ShieldReactiveController} from "../../src/reactive/ShieldReactiveController.sol";

/// @notice Phase 3, origin/Reactive side (Reactive Lasna, chain 5318007).
///
/// Deploys the ShieldReactiveController on Lasna and funds it with REACT so it
/// can pay for reactive transactions + callbacks. Subscriptions are created in
/// the constructor (RiskRegimeChanged on Base Sepolia + CRON on Lasna).
///
/// Env (all required unless noted):
///  - REACTIVE_PRIVATE_KEY   broadcaster on Lasna (funded with lREACT from faucet)
///  - ORIGIN_CHAIN_ID        e.g. 84532 (Base Sepolia, where the hook lives)
///  - SHIELD_HOOK            deployed hook address on the origin chain
///  - DESTINATION_CHAIN_ID   e.g. 84532 (where the executor lives)
///  - SHIELD_EXECUTOR        deployed ShieldReactiveExecutor address (destination)
///  - TARGET_POOL_ID         bytes32 poolId to sweep on CRON
///  - CRON_SYSTEM            CRON system-contract address on Lasna (network param)
///  - CRON_TOPIC0            topic0 of the chosen CRON cadence (network param)
///  - CONTROLLER_FUNDING_WEI optional; msg.value sent to controller (default 0,
///    fund separately via faucet `request`/`depositTo` if 0)
///
/// CRON_SYSTEM / CRON_TOPIC0 are intentionally NOT hardcoded: the cron cadence is
/// a Reactive network parameter and must be taken from the live deployment docs
/// at deploy time. See docs/product/reactive-lp-shield-execution-plan.md.
contract DeployReactiveControllerLasna is Script {
    uint256 private constant LASNA_CHAIN_ID = 5318007;

    function run() external {
        require(block.chainid == LASNA_CHAIN_ID, "wrong chain: expected Reactive Lasna 5318007");

        uint256 pk = vm.envUint("REACTIVE_PRIVATE_KEY");
        uint256 originChainId = vm.envUint("ORIGIN_CHAIN_ID");
        address shieldHook = vm.envAddress("SHIELD_HOOK");
        uint256 destChainId = vm.envUint("DESTINATION_CHAIN_ID");
        address executor = vm.envAddress("SHIELD_EXECUTOR");
        bytes32 targetPoolId = vm.envBytes32("TARGET_POOL_ID");
        address cronSystem = vm.envAddress("CRON_SYSTEM");
        uint256 cronTopic0 = vm.envUint("CRON_TOPIC0");
        uint256 funding = vm.envOr("CONTROLLER_FUNDING_WEI", uint256(0));

        vm.startBroadcast(pk);
        ShieldReactiveController controller = new ShieldReactiveController{value: funding}(
            originChainId, shieldHook, destChainId, executor, PoolId.wrap(targetPoolId), cronSystem, cronTopic0
        );
        vm.stopBroadcast();

        console2.log("network", "reactive-lasna");
        console2.log("controller", address(controller));
        console2.log("originChainId", originChainId);
        console2.log("shieldHook", shieldHook);
        console2.log("destinationChainId", destChainId);
        console2.log("executor", executor);
        console2.logBytes32(targetPoolId);
        console2.log("cronSystem", cronSystem);
        console2.log("fundedWei", funding);
        console2.log(
            "NEXT: ensure controller is funded (coverDebt if inactive) and re-point executor.authorizedReactive to this controller address."
        );
    }
}
