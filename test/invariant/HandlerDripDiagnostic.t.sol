// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {Constants} from "@uniswap/v4-core/test/utils/Constants.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {IPositionManager} from "@uniswap/v4-periphery/src/interfaces/IPositionManager.sol";

import {EasyPosm} from "../utils/libraries/EasyPosm.sol";
import {BaseTest} from "../utils/BaseTest.sol";
import {DirectionalToxicityShieldHarness} from "../harness/DirectionalToxicityShieldHarness.sol";
import {DirectionalToxicityShield} from "../../src/DirectionalToxicityShield.sol";
import {ShieldInvariantHandler} from "./ShieldInvariantHandler.sol";

/// @notice Deterministic diagnostic: prove the handler CAN exercise capture and
/// drip when driven by hand. If this passes, the invariant handler's action set
/// is capable of reaching drip; if drip still never fires under fuzzing, the
/// problem is reachability/ordering, not capability.
contract HandlerDripDiagnostic is BaseTest {
    using EasyPosm for IPositionManager;
    using PoolIdLibrary for PoolKey;

    DirectionalToxicityShieldHarness internal hook;
    ShieldInvariantHandler internal handler;
    Currency internal currency0;
    Currency internal currency1;
    PoolKey internal key;
    PoolId internal poolId;

    function setUp() public {
        deployArtifactsAndLabel();
        (currency0, currency1) = deployCurrencyPair();
        address flags = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.AFTER_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG
                    | Hooks.AFTER_SWAP_FLAG | Hooks.AFTER_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo(
            "DirectionalToxicityShieldHarness.sol:DirectionalToxicityShieldHarness", abi.encode(poolManager), flags
        );
        hook = DirectionalToxicityShieldHarness(flags);
        key = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 60, IHooks(hook));
        poolId = key.toId();

        poolManager.initialize(key, Constants.SQRT_PRICE_1_1);
        int24 tickLower = TickMath.minUsableTick(key.tickSpacing);
        int24 tickUpper = TickMath.maxUsableTick(key.tickSpacing);
        uint128 liq = 100e18;
        (uint256 a0, uint256 a1) = LiquidityAmounts.getAmountsForLiquidity(
            Constants.SQRT_PRICE_1_1, TickMath.getSqrtPriceAtTick(tickLower), TickMath.getSqrtPriceAtTick(tickUpper), liq
        );
        positionManager.mint(key, tickLower, tickUpper, liq, a0 + 1, a1 + 1, address(this), block.timestamp, Constants.ZERO_BYTES);

        hook.setFeePolicy(poolId, 3000, 500, 10000, 500, 10, 500, 500_000, 30, 5 minutes, 0, 5);
        hook.configureSmoothing(
            key, DirectionalToxicityShield.SmoothingConfig({enabled: true, dripBlockInterval: 5, dripBps: 2000})
        );

        handler = new ShieldInvariantHandler(hook, swapRouter, key, currency0, currency1);
        currency0.transfer(address(handler), 1_000_000 ether);
        currency1.transfer(address(handler), 1_000_000 ether);
        vm.startPrank(address(handler));
        IERC20A(Currency.unwrap(currency0)).approve(address(swapRouter), type(uint256).max);
        IERC20A(Currency.unwrap(currency1)).approve(address(swapRouter), type(uint256).max);
        vm.stopPrank();
    }

    function test_diag_captureThenDripFires() public {
        // 1) Build reserve via an aligned swap under positive pressure.
        handler.setPressure(200);
        handler.swap(false, 2e18); // zeroForOne=false aligns with +pressure
        DirectionalToxicityShield.SmoothingReserve memory afterCapture = hook.getSmoothingReserve(poolId);
        emit log_named_uint("captured0", afterCapture.reserve0);
        emit log_named_uint("captured1", afterCapture.reserve1);
        emit log_named_uint("ghostCaptured0", handler.ghostCaptured0());

        // 2) Quiet + cooldown, then a small swap should drip.
        handler.quietThenSwap(1e17);
        emit log_named_uint("dripCount", handler.dripCount());
        emit log_named_uint("ghostDripped0", handler.ghostDripped0());
        emit log_named_uint("ghostDripped1", handler.ghostDripped1());

        assertGt(handler.ghostCaptured0() + handler.ghostCaptured1(), 0, "no capture");
        assertGt(handler.dripCount(), 0, "no drip");
    }
}

interface IERC20A {
    function approve(address s, uint256 a) external returns (bool);
}
