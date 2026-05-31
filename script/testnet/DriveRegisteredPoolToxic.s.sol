// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console2} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {IERC20} from "forge-std/interfaces/IERC20.sol";

import {AddressConstants} from "hookmate/constants/AddressConstants.sol";
import {IUniswapV4Router04} from "hookmate/interfaces/router/IUniswapV4Router04.sol";

import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";

/// @title Drive the already-registered pool toxic on Base Sepolia.
/// @notice One-shot script: approves tokens to the v4 swap router and pushes
///         pressure into the *registered* pool (the one the executor accepts).
///         Run once, wait > decayWindow, then run DriveRegisteredPoolQuiet.s.sol.
contract DriveRegisteredPoolToxic is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address hookAddr = vm.envAddress("DTS_HOOK_ADDRESS");
        address t0 = vm.envAddress("REG_POOL_TOKEN0");
        address t1 = vm.envAddress("REG_POOL_TOKEN1");

        IUniswapV4Router04 router = IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));
        DirectionalToxicityShield hook = DirectionalToxicityShield(hookAddr);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        vm.startBroadcast(pk);
        if (IERC20(t0).allowance(vm.addr(pk), address(router)) == 0) {
            IERC20(t0).approve(address(router), type(uint256).max);
        }
        if (IERC20(t1).allowance(vm.addr(pk), address(router)) == 0) {
            IERC20(t1).approve(address(router), type(uint256).max);
        }

        // 4 same-direction swaps of 0.5 ETH-units to push pressure past max/2 (regime 2 = toxic).
        // Each swap is its own broadcast tx => different block => bypasses the same-block guard.
        for (uint256 i = 0; i < 4; i++) {
            router.swapExactTokensForTokens({
                amountIn: 5e17,
                amountOutMin: 0,
                zeroForOne: true,
                poolKey: key,
                hookData: bytes(""),
                receiver: vm.addr(pk),
                deadline: block.timestamp + 1 hours
            });
        }
        vm.stopBroadcast();

        DirectionalToxicityShield.DirectionalState memory s = hook.getDirectionalState(key.toId());
        console2.log("post-toxic regime:", uint256(s.regime));
        console2.log("post-toxic pressure:", int256(s.pressure));
        console2.log("post-toxic lastFee:", uint256(s.lastFee));
        console2.log("waitTime: > 300 s before running quiet phase");
    }
}
