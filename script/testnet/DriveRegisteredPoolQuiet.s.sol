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

/// @title Bring the registered pool back to quiet → emits RiskRegimeChanged(→0).
/// @notice Run AFTER waiting > decayWindow (300 s) past the toxic phase. The
///         hook's _updatePressure decays pressure to 0 over decayWindow, so a
///         tiny next swap that adds <majorMoveThreshold pressure leaves
///         pressure=0 and triggers the regime transition (->0).
contract DriveRegisteredPoolQuiet is Script {
    using PoolIdLibrary for PoolKey;

    function run() external {
        uint256 pk = vm.envUint("DEPLOYER_PRIVATE_KEY");
        address hookAddr = vm.envAddress("DTS_HOOK_ADDRESS");
        address t0 = vm.envAddress("REG_POOL_TOKEN0");
        address t1 = vm.envAddress("REG_POOL_TOKEN1");

        IUniswapV4Router04 router =
            IUniswapV4Router04(payable(AddressConstants.getV4SwapRouterAddress(block.chainid)));
        DirectionalToxicityShield hook = DirectionalToxicityShield(hookAddr);

        PoolKey memory key = PoolKey({
            currency0: Currency.wrap(t0),
            currency1: Currency.wrap(t1),
            fee: LPFeeLibrary.DYNAMIC_FEE_FLAG,
            tickSpacing: 60,
            hooks: IHooks(hookAddr)
        });

        DirectionalToxicityShield.DirectionalState memory pre = hook.getDirectionalState(key.toId());
        console2.log("pre-quiet regime:", uint256(pre.regime));
        console2.log("pre-quiet pressure:", int256(pre.pressure));

        vm.startBroadcast(pk);
        // Tiny swap so introducedPressure < majorMoveThreshold; combined with full decay
        // window elapsed, decayedPressure=0 + 0 = 0 -> regime 0 -> RiskRegimeChanged(...,0).
        router.swapExactTokensForTokens({
            amountIn: 1e15,
            amountOutMin: 0,
            zeroForOne: true,
            poolKey: key,
            hookData: bytes(""),
            receiver: vm.addr(pk),
            deadline: block.timestamp + 1 hours
        });
        vm.stopBroadcast();

        DirectionalToxicityShield.DirectionalState memory post = hook.getDirectionalState(key.toId());
        console2.log("post-quiet regime:", uint256(post.regime));
        console2.log("post-quiet pressure:", int256(post.pressure));
    }
}
