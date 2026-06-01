// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";
import {ShieldReactiveExecutor} from "../../src/reactive/ShieldReactiveExecutor.sol";
import {IDirectionalToxicityShield} from "../../src/reactive/IDirectionalToxicityShield.sol";

/// @notice Redeploys ONLY the ShieldReactiveExecutor against the existing hook
/// and pool, then rewires the hook's reactive executor pointer.
///
/// Used to ship the rvm_id auth fix without re-deploying the hook, tokens, or
/// liquidity. The hook configurer (= deployer EOA) is allowed to call
/// `setReactiveExecutor` so this script must be broadcast by the same EOA that
/// initialized the existing pool.
///
/// Env (all required):
///  - DEPLOYER_PRIVATE_KEY   broadcaster (must equal the existing pool configurer)
///  - DTS_HOOK_ADDRESS       existing DirectionalToxicityShield hook
///  - REG_POOL_TOKEN0        token0 of the existing registered pool
///  - REG_POOL_TOKEN1        token1 of the existing registered pool
///  - CALLBACK_PROXY         destination callback proxy (Base Sepolia: 0xa6eA…A5a6)
contract RedeployExecutorBaseSepolia is Script {
    using PoolIdLibrary for PoolKey;

    uint256 private constant BASE_SEPOLIA_CHAIN_ID = 84532;

    function run() external {
        require(block.chainid == BASE_SEPOLIA_CHAIN_ID, "wrong chain: expected Base Sepolia 84532");

        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address deployer = vm.addr(pk);
        address hookAddr = vm.envAddress("DTS_HOOK_ADDRESS");
        address t0 = vm.envAddress("REG_POOL_TOKEN0");
        address t1 = vm.envAddress("REG_POOL_TOKEN1");
        address callbackProxy = vm.envAddress("CALLBACK_PROXY");

        DirectionalToxicityShield hook = DirectionalToxicityShield(hookAddr);
        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });
        PoolId poolId = key.toId();

        // Sanity: deployer must be configurer (otherwise setReactiveExecutor reverts).
        require(hook.getPoolConfigurer(poolId) == deployer, "deployer is not pool configurer");

        vm.startBroadcast(pk);

        ShieldReactiveExecutor executor =
            new ShieldReactiveExecutor(callbackProxy, IDirectionalToxicityShield(address(hook)), deployer);
        executor.registerPool(key);
        hook.setReactiveExecutor(key, address(executor));

        vm.stopBroadcast();

        console2.log("network", "base-sepolia");
        console2.log("deployer", deployer);
        console2.log("hook", address(hook));
        console2.log("newExecutor", address(executor));
        console2.log("callbackProxy", callbackProxy);
        console2.logBytes32(PoolId.unwrap(poolId));
        console2.log(
            "NEXT: deploy new controller on Lasna with this newExecutor + same poolId, then call newExecutor.setController(newController, controllerRvmId) where controllerRvmId is the EOA broadcasting the Lasna deploy."
        );
    }
}
